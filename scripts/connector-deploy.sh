#!/bin/zsh
# Thin wrapper, kept at ~/agentvault/connector-deploy.sh because the connector's POST /hooks/deploy runs "/bin/zsh <this path>" with DEPLOY_HOOK=1
# (memory/agentvault/remote/__main__.py). The real work is the pull-based deployer: docs/deploy-pipeline.md.
D=/usr/local/dex-deployer
exec /bin/bash "$D/dex-deployer.sh" "$D/targets/personal.conf"
