import fs from "node:fs";
import path from "node:path";
import { defineToolPlugin } from "openclaw/plugin-sdk/tool-plugin";
import { upscaleFile } from "./image-upscale.mjs";

const WORKLOAD_ROOT = "/home/node/.openclaw/workspace/complex-workload";

const IMAGE_UPSCALE_PARAMETERS = {
  type: "object",
  additionalProperties: false,
  required: ["input_path", "output_path"],
  properties: {
    input_path: { type: "string", description: "Input PGM path under /home/node/.openclaw/workspace/complex-workload." },
    output_path: { type: "string", description: "Output PGM path under /home/node/.openclaw/workspace/complex-workload." },
    scale: { type: "integer", description: "Dimension scale; the benchmark requires 2.", minimum: 2, maximum: 2, default: 2 },
    passes: { type: "integer", description: "Deterministic smoothing passes used to make CPU work measurable.", minimum: 1, maximum: 100000, default: 512 },
  },
};

function workloadPath(value, field) {
  if (typeof value !== "string" || value.length === 0) throw new Error(`${field} is required`);
  const resolved = path.resolve(value);
  if (resolved !== WORKLOAD_ROOT && !resolved.startsWith(`${WORKLOAD_ROOT}${path.sep}`)) {
    throw new Error(`${field} must stay under ${WORKLOAD_ROOT}`);
  }
  return resolved;
}

export default defineToolPlugin({
  id: "image-upscale",
  name: "Image Upscale Benchmark",
  description: "Upscale a deterministic local PGM image with a reproducible CPU workload.",
  tools: (tool) => [
    tool({
      name: "image_upscale",
      label: "Image Upscale",
      description: "Read a PGM image, double both dimensions (4x pixels), and write a validated output under the benchmark workspace.",
      parameters: IMAGE_UPSCALE_PARAMETERS,
      execute: async ({ input_path, output_path, scale = 2, passes = 512 }) => {
        if (scale !== 2) throw new Error("the benchmark requires scale=2");
        const input = workloadPath(input_path, "input_path");
        const output = workloadPath(output_path, "output_path");
        const result = {
          tool: "image_upscale",
          ...upscaleFile(input, output, ["--scale", String(scale), "--passes", String(passes)]),
        };
        fs.writeFileSync(output + ".json", JSON.stringify(result) + "\n", { mode: 0o644 });
        return result;
      },
    }),
  ],
});
