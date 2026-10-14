# CI must finish successfully on the exact PR head before all other checks gate merge.
(.ci.status == "completed" and .ci.conclusion == "success") and
([.checks[] | select(.name != "Enable auto-merge after required checks")] as $checks |
  ($checks | length) > 0 and
  all($checks[];
    if .__typename == "CheckRun" then
      .status == "COMPLETED" and
      (.conclusion == "SUCCESS" or .conclusion == "SKIPPED" or .conclusion == "NEUTRAL")
    else .state == "SUCCESS" end))
