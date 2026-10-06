# Development

## Tooling

```bash
brew install shellcheck shfmt
```

```bash
bash -n vault-backup.sh                 # syntax check
shellcheck vault-backup.sh              # lint
shfmt -i 4 -ci -bn -d vault-backup.sh   # check formatting (add -w to apply)
```

`# shellcheck source=/dev/null` comments before each `source` are intentional. The config paths are built at runtime, so SC1090 can't follow them. Same for the `disable=SC2012` above `ls`: the timestamped bundle names make lexical order equal chronological order, which `find` can't provide.
