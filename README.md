# 1 Million Dollar (1MD)

A plain, fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum mainnet.

| Field | Value |
|---|---|
| Solidity contract | `OneMillionDollarToken` (`src/OneMillionDollarToken.sol`) |
| `name()` | `1 Million Dollar` |
| `symbol()` | `1MD` |
| `decimals()` | `18` |
| `totalSupply()` | `1_000_000_000 * 10**18` = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Minting | once, in the constructor, the whole supply to `msg.sender` (the launch factory) |
| Owner / admin | none |

## What the contract does

`OneMillionDollarToken` inherits OpenZeppelin Contracts v5.4.0 `ERC20` and adds nothing but the
constants above and a constructor that mints `INITIAL_SUPPLY` to `msg.sender`. That is the entire
behaviour:

- Standard ERC-20 `transfer`, `transferFrom`, `approve`, `allowance`, `balanceOf`, `totalSupply`
  and the metadata getters, with OpenZeppelin v5's custom errors (`ERC20InsufficientBalance`,
  `ERC20InsufficientAllowance`, `ERC20InvalidReceiver`, `ERC20InvalidSpender`).
- No fee, tax, reflection or burn on transfer: every transfer delivers exactly the amount sent.
- No `mint`, `burn` or `burnFrom`. The supply is fixed at deployment and can never grow or be
  reduced by anyone else's hand. (A holder can still send tokens to a dead address themselves;
  the zero address is refused.)
- No owner, `Ownable`, `AccessControl`, pause, blocklist, freeze or seize. There is no privileged
  caller at all, so there is nothing to transfer or renounce after launch.
- No proxy, `delegatecall`, `callcode` or `selfdestruct`.
- Rejects plain ether (no `receive` / `fallback`).

## Assumptions

- **The deployer is the launch factory.** The constructor mints to `msg.sender`, which under
  `ProjectFactory.launchCustom` is the factory. The factory then forwards the supply: 10% to the
  launch's MerkleDistributor, 80% (`poolBps = 8000`) to seed the Uniswap v4 pool, and the
  remaining 10% to `economics.remainderTo`. Because there is no fee on transfer, each of those
  flows arrives whole, and traders can buy from and sell into the PoolManager without any exemption
  list. The token therefore does not take `$factory`, `$poolManager` or `$launchNumber` as
  constructor arguments: it has nothing to exempt.
- **Fixed supply is the product.** The brief asks for 1,000,000,000 tokens minted once; nothing
  in the contract can change that number after deployment.
- **No governance or upgrade path.** The contract is immutable. A behaviour change means a new
  token, not an upgrade.
- **Compiler.** `foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer on with
  200 runs, `via_ir = false`, and `bytecode_hash = "none"` so the deployed bytes are reproducible
  without a metadata hash. `ffi` is off and `fs_permissions` is empty.

## Deployment parameters

There are none. The creation code has no constructor arguments, so the bytecode the launch hashes is
exactly `type(OneMillionDollarToken).creationCode`, and every deployment of it is byte-identical.

For the launch manifest (written by the manifest step, not by this repository):

- `token.contract`: `OneMillionDollarToken`
- `token.name`: `1 Million Dollar`
- `token.symbol`: `1MD`
- `token.decimals`: `18`
- `token.constructorArgs`: `[]`
- `token.totalSupply`: `1000000000000000000000000000`
- application contracts: none

Launch values decided by the launch itself (chain id 1, IMD pair at
`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, pool fee 12500, tick spacing 60, the requester's
`economics`) are not encoded in the token and need no action here.

`script/Deploy.s.sol` is a reviewable helper only. Its `deploy()` function deploys the token to
whoever calls it and is exercised by the tests; `run()` wraps it in a broadcast for a local or
reviewer deployment. It reads no environment variables and is not part of the IdentityMD launch,
which deploys the attested bytecode through the factory.

## Operational responsibilities

- **After launch: nothing to configure.** There is no owner, no setter and no role. No key needs to
  be rotated, handed to a multisig or renounced.
- **The factory's forwarding is the only distribution step.** Once the factory has moved the
  swarm's share, seeded the pool and sent the remainder to `economics.remainderTo`, the factory
  holds nothing and has no further power over the token.
- **Holders are responsible for their own keys and approvals.** Allowances are standard ERC-20:
  `type(uint256).max` is treated as infinite and never decremented; anything smaller is reduced on
  each `transferFrom`. Approve only what is needed.
- **Explorer verification** of the deployed source belongs to the launch's deployer and policy; the
  pinned compiler settings in `foundry.toml` are what it needs to reproduce the bytecode.
- **Security review.** The suite below is not an audit. The contract is a thin wrapper over an
  audited library with zero custom logic beyond a constant mint, which is the point: there is no
  surface to review beyond confirming the constants.

## Repository layout

```
foundry.toml                 compiler pins and project settings
remappings.txt               forge-std/ and @openzeppelin/contracts/ -> lib/
src/OneMillionDollarToken.sol
script/Deploy.s.sol
test/OneMillionDollarToken.t.sol
lib/forge-std/               forge-std v1.9.7, vendored as plain files (src/ only)
lib/openzeppelin-contracts/  OpenZeppelin Contracts v5.4.0, vendored as plain files (contracts/ only)
```

Dependencies are committed as ordinary files, not git submodules, so the project builds offline.

## Build and test

```
forge build
forge test
forge fmt --check
```

Fuzz tests run with the default 256 runs; the verifier runs them with a fixed seed and the suite has
been run with that seed. Tests read no environment variables, depend on no caller address, and are
order- and parallel-safe.

The suite covers:

- metadata, decimals and the exact supply constant;
- the whole supply minted once to the deployer, including through a CREATE2 factory stand-in, with
  exactly one `Transfer(0x0, deployer, supply)` event and a byte-identical runtime per deployment;
- the deploy script's `deploy()` path;
- transfer, approve and transferFrom success paths, including infinite allowance semantics;
- failure paths: insufficient balance, insufficient and missing allowance, zero-address receiver,
  zero-address spender, and ether sent to the token;
- the fixed supply: twelve common mint/admin selectors and fourteen pause/freeze/seize/burn
  selectors are all absent, from both an attacker and the deployer, and a holder keeps and can move
  their balance afterwards;
- runtime bytecode contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` and is under the
  EIP-170 limit;
- the launch flows (10% to the distributor and onward to a claimant, 80% pool, 10% remainder)
  arrive whole;
- fuzzed conservation of supply and exactness over single and multi-hop transfers, allowance
  enforcement and balance enforcement.

## Licence

MIT for this repository's own files. Vendored dependencies keep their own licences
(`lib/forge-std/LICENSE-MIT`, `lib/forge-std/LICENSE-APACHE`, `lib/openzeppelin-contracts/LICENSE`).
