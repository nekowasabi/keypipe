# config-trigger

## Sub-features

One JSON config file maps a trigger string (`@@@`) to an action (shell
command or log line). Bad config fails loud: non-zero exit or stderr error.

## How to get to it (user POV)

Copy `config.example.json`, set a trigger and command, run
`keypipe --config <file>`. Type the trigger, see the action fire.

## Driving it with verify.sh

V3a-V3c: example file plus README format doc, `python3` JSON validity with
`@@@` and `rules` keys, invalid-config run expecting non-zero exit or an
error line (static error-path grep when no binary).

## Gotchas

Only JSON is accepted in MVP. TOML/YAML configs are out of scope.
