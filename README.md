# market-registry

The Cork `MarketRegistry` Solidity contracts: the registry itself, the oracle
adapter factories, the recipe contracts, and the 1inch limit-order adapter.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`), solc `0.8.30`.

Fetch every dependency, including the nested submodules under `lib/phoenix`,
before building:

```bash
git submodule update --init --recursive
```

## Build and test

```bash
forge build --sizes                   # compile, report contract sizes
forge test -vvv                       # run the test suite
FOUNDRY_PROFILE=lop forge test        # 1inch end-to-end test (needs via_ir)
```

The default profile deliberately skips `test/CorkLopE2E.t.sol`; that test only
compiles with `via_ir`, which is why it lives behind the `lop` profile.

## Deployments

Deployed addresses are published in the notes of each
[GitHub Release](https://github.com/Cork-Technology/market-registry/releases).

> The current canonical address set for every Cork deployment lives at
> <https://docs.cork.tech/>.

## Conventions

- Solidity `0.8.30`, EVM `cancun`, optimizer on at 200 runs.
- Always use a real error selector in `vm.expectRevert(...)`, never a bare
  `vm.expectRevert()`.
- Recipe bands are percentages in the Phoenix convention: `1e18` means `1%`.
