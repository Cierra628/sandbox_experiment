group_by(.handler)
| map(
    . as $all
    | (map(select(.status == "PASS"))) as $p
    | {
        handler: .[0].handler,
        runs: length,
        passed: ($p | length),
        averages_ms:
          (if ($p | length) == 0 then null
          else {
            runp: ($p | map(.runp_ms) | add / length),
            create: ($p | map(.create_ms) | add / length),
            start: ($p | map(.start_ms) | add / length),
            gateway_ready: ($p | map(.gateway_ready_ms) | add / length),
            exec_true: ($p | map(.exec_true_ms) | add / length),
            exec_node: ($p | map(.exec_node_ms) | add / length),
            health_exec: ($p | map(.health_exec_ms) | add / length),
            health_internal: ($p | map(.health_internal_ms) | add / length),
            sample_exec: ($p | map(select(.sample_exec_ms > 0) | .sample_exec_ms) as $v | if ($v|length)>0 then ($v|add/length) else 0 end),
            sample_internal: ($p | map(select(.sample_internal_ms > 0) | .sample_internal_ms) as $v | if ($v|length)>0 then ($v|add/length) else 0 end),
            cleanup: ($p | map(.cleanup_ms) | add / length),
            total: ($p | map(.total_ms) | add / length)
          } end)
      }
  )
