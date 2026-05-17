.runs[] | select(.tool.driver.name == $linter) |
"# Linter: \(.tool.driver.name)\n\n**Total findings:** \(.results | length)\n\n---\n\n" +
([.results | group_by(.locations[0].physicalLocation.artifactLocation.uri)[] |
    "## File: \(.[0].locations[0].physicalLocation.artifactLocation.uri)\n\n" +
    (map(
        "- **Line \(.locations[0].physicalLocation.region.startLine // "?")**" +
        " [\(.ruleId // "unknown")]" +
        (if .level then " `\(.level)`" else "" end) +
        "\n  ```\n  \(.message.text)\n  ```" +
        (if .fixes then "\n  **Auto-fixable**" else "" end)
    ) | join("\n\n"))
] | join("\n\n"))
