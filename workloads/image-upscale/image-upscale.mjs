#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { pathToFileURL } from "node:url";

function usage() {
  console.error(`Usage:
  image-upscale.mjs generate OUTPUT.pgm [--width N] [--height N] [--seed N]
  image-upscale.mjs upscale INPUT.pgm OUTPUT.pgm [--scale 2] [--passes N]`);
}

function option(args, name, fallback) {
  const index = args.indexOf(name);
  if (index === -1) return fallback;
  const value = args[index + 1];
  if (value === undefined) throw new Error(`missing value for ${name}`);
  return value;
}

function positiveInteger(value, name, { minimum = 1, maximum = 100000 } = {}) {
  if (!/^[0-9]+$/.test(String(value))) {
    throw new Error(`${name} must be an integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${name} must be in [${minimum}, ${maximum}]`);
  }
  return parsed;
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function readToken(bytes, start) {
  let index = start;
  while (index < bytes.length) {
    const current = bytes[index];
    if (current === 35) {
      while (index < bytes.length && bytes[index] !== 10) index += 1;
      continue;
    }
    if (current === 9 || current === 10 || current === 13 || current === 32) {
      index += 1;
      continue;
    }
    break;
  }
  const begin = index;
  while (index < bytes.length) {
    const current = bytes[index];
    if (current === 9 || current === 10 || current === 13 || current === 32 || current === 35) {
      break;
    }
    index += 1;
  }
  if (begin === index) throw new Error("missing PGM header token");
  return { value: Buffer.from(bytes.subarray(begin, index)).toString("ascii"), end: index };
}

function parsePgm(bytes, sourcePath) {
  const magic = readToken(bytes, 0);
  const width = readToken(bytes, magic.end);
  const height = readToken(bytes, width.end);
  const maxValue = readToken(bytes, height.end);
  if (magic.value !== "P5") throw new Error(`${sourcePath}: expected binary PGM (P5)`);
  const parsedWidth = positiveInteger(width.value, "PGM width", { maximum: 10000 });
  const parsedHeight = positiveInteger(height.value, "PGM height", { maximum: 10000 });
  if (maxValue.value !== "255") throw new Error(`${sourcePath}: only maxval 255 is supported`);

  let dataStart = maxValue.end;
  if (bytes[dataStart] === 13 && bytes[dataStart + 1] === 10) dataStart += 2;
  else if (bytes[dataStart] === 9 || bytes[dataStart] === 10 || bytes[dataStart] === 13 || bytes[dataStart] === 32) dataStart += 1;
  const expected = parsedWidth * parsedHeight;
  const pixels = bytes.subarray(dataStart);
  if (pixels.length !== expected) {
    throw new Error(`${sourcePath}: expected ${expected} pixels, found ${pixels.length}`);
  }
  return { width: parsedWidth, height: parsedHeight, pixels: Uint8Array.from(pixels) };
}

function encodePgm(width, height, pixels) {
  const header = Buffer.from(`P5\n${width} ${height}\n255\n`, "ascii");
  return Buffer.concat([header, Buffer.from(pixels)]);
}

function generatePgm(width, height, seed) {
  const pixels = new Uint8Array(width * height);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      pixels[y * width + x] = (x * 17 + y * 31 + seed * 13 + x * y * 7) & 0xff;
    }
  }
  return { width, height, pixels };
}

function bilinearUpscale(input, scale) {
  const width = input.width * scale;
  const height = input.height * scale;
  const output = new Uint8Array(width * height);
  for (let y = 0; y < height; y += 1) {
    const sourceY = (y + 0.5) / scale - 0.5;
    const y0 = Math.max(0, Math.floor(sourceY));
    const y1 = Math.min(input.height - 1, y0 + 1);
    const fy = Math.max(0, Math.min(1, sourceY - y0));
    for (let x = 0; x < width; x += 1) {
      const sourceX = (x + 0.5) / scale - 0.5;
      const x0 = Math.max(0, Math.floor(sourceX));
      const x1 = Math.min(input.width - 1, x0 + 1);
      const fx = Math.max(0, Math.min(1, sourceX - x0));
      const top = input.pixels[y0 * input.width + x0] * (1 - fx) + input.pixels[y0 * input.width + x1] * fx;
      const bottom = input.pixels[y1 * input.width + x0] * (1 - fx) + input.pixels[y1 * input.width + x1] * fx;
      output[y * width + x] = Math.round(top * (1 - fy) + bottom * fy);
    }
  }
  return output;
}

function smoothPass(pixels, width, height) {
  const output = new Uint8Array(pixels.length);
  for (let y = 0; y < height; y += 1) {
    const y0 = Math.max(0, y - 1);
    const y1 = Math.min(height - 1, y + 1);
    for (let x = 0; x < width; x += 1) {
      const x0 = Math.max(0, x - 1);
      const x1 = Math.min(width - 1, x + 1);
      let total = 0;
      let weight = 0;
      for (let yy = y0; yy <= y1; yy += 1) {
        for (let xx = x0; xx <= x1; xx += 1) {
          const distance = Math.abs(xx - x) + Math.abs(yy - y);
          const currentWeight = distance === 0 ? 4 : distance === 1 ? 2 : 1;
          total += pixels[yy * width + xx] * currentWeight;
          weight += currentWeight;
        }
      }
      output[y * width + x] = Math.round(total / weight);
    }
  }
  return output;
}

function roundMs(value) {
  return Number(value.toFixed(3));
}

function generate(outputPath, args) {
  const width = positiveInteger(option(args, "--width", "32"), "width", { maximum: 2048 });
  const height = positiveInteger(option(args, "--height", "32"), "height", { maximum: 2048 });
  const seed = positiveInteger(option(args, "--seed", "7"), "seed", { minimum: 0, maximum: 0xffffffff });
  const image = encodePgm(width, height, generatePgm(width, height, seed).pixels);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, image);
  return {
    ok: true,
    operation: "generate",
    path: outputPath,
    bytes: image.length,
    width,
    height,
    pixels: width * height,
    seed,
    sha256: sha256(image),
  };
}

function upscaleFile(inputPath, outputPath, args = []) {
  const scale = positiveInteger(option(args, "--scale", "2"), "scale", { minimum: 2, maximum: 4 });
  const passes = positiveInteger(option(args, "--passes", "512"), "passes", { minimum: 1, maximum: 100000 });
  const readStarted = performance.now();
  const inputBytes = fs.readFileSync(inputPath);
  const input = parsePgm(inputBytes, inputPath);
  const readMs = performance.now() - readStarted;

  const computeStarted = performance.now();
  let pixels = bilinearUpscale(input, scale);
  const outputWidth = input.width * scale;
  const outputHeight = input.height * scale;
  for (let pass = 0; pass < passes; pass += 1) pixels = smoothPass(pixels, outputWidth, outputHeight);
  const computeMs = performance.now() - computeStarted;

  const writeStarted = performance.now();
  const outputBytes = encodePgm(outputWidth, outputHeight, pixels);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, outputBytes);
  const writeMs = performance.now() - writeStarted;

  return {
    ok: true,
    operation: "upscale",
    algorithm: "bilinear-plus-iterative-3x3-smoothing",
    scale,
    passes,
    input: {
      path: inputPath,
      bytes: inputBytes.length,
      width: input.width,
      height: input.height,
      pixels: input.width * input.height,
      sha256: sha256(inputBytes),
    },
    output: {
      path: outputPath,
      bytes: outputBytes.length,
      width: outputWidth,
      height: outputHeight,
      pixels: outputWidth * outputHeight,
      sha256: sha256(outputBytes),
    },
    timing_ms: {
      read: roundMs(readMs),
      compute: roundMs(computeMs),
      write: roundMs(writeMs),
      total: roundMs(readMs + computeMs + writeMs),
    },
  };
}

function main(argv) {
  const [operation, first, second, ...args] = argv;
  if (operation === "generate" && first) return generate(path.resolve(first), [second, ...args].filter((value) => value !== undefined));
  if (operation === "upscale" && first && second) return upscaleFile(path.resolve(first), path.resolve(second), args);
  usage();
  process.exitCode = 2;
  return { ok: false, error: "invalid arguments" };
}

export { encodePgm, generatePgm, parsePgm, upscaleFile };

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    console.log(JSON.stringify(main(process.argv.slice(2))));
  } catch (error) {
    console.error(`image-upscale: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
