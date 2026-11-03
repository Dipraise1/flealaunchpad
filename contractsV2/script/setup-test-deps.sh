#!/usr/bin/env bash
# Fetches the full Uniswap V4 stack used only by test/Graduation.t.sol.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d test-lib/v4-periphery ] || git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/Uniswap/v4-periphery.git test-lib/v4-periphery
(cd test-lib/v4-periphery && forge build src/PositionManager.sol lib/v4-core/src/PoolManager.sol lib/v4-core/src/test/PoolSwapTest.sol)
