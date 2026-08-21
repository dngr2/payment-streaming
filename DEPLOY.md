# Deploying StreamManager

`script/Deploy.s.sol` deploys the single `StreamManager` contract. It does **not**
create any streams — those are created after deployment by calling
`createStream(...)` (or `createStreamBatch(...)`) once the contract is live.

> **Unaudited.** This code has not been through a professional security audit. Deploy
> to a testnet first, and do not put material funds at risk on mainnet without an audit.

## Constructor parameters

`StreamManager` takes three constructor arguments, supplied here via environment variables:

| Env var         | Type      | Meaning                                                                 |
| --------------- | --------- | ----------------------------------------------------------------------- |
| `OWNER`         | `address` | Protocol owner. Fee configuration only — **cannot** touch stream funds. |
| `FEE_RECIPIENT` | `address` | Receives the creation fee skimmed once at stream creation.              |
| `FEE_BPS`       | `uint256` | Initial protocol fee in basis points. Must be `<= 1000` (10% cap).      |

Set `FEE_BPS=0` for a zero-fee deployment.

## Environment

Deploy with a **dedicated deployer key** — a throwaway key funded with just enough
gas for this deployment, not a key holding real funds. Never commit it; keep it in a
`.env` file (already git-ignored) or export it in your shell.

```sh
export OWNER=0xYourOwnerAddress
export FEE_RECIPIENT=0xYourFeeRecipientAddress
export FEE_BPS=0

export RPC_URL=https://your-testnet-rpc
export PRIVATE_KEY=0xYourDedicatedDeployerKey   # dedicated, low-value deployer key
```

## Deploy (testnet first)

Dry run (no broadcast):

```sh
forge script script/Deploy.s.sol:DeployScript --rpc-url "$RPC_URL"
```

Broadcast to a testnet:

```sh
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

The deployed address is printed to the console (`StreamManager deployed at: ...`).

## Verification

Add Etherscan verification with `--verify --etherscan-api-key "$ETHERSCAN_API_KEY"`.
Verification depends on your having a valid API key for the target explorer and on the
compiler settings matching `foundry.toml` (solc 0.8.26, `via_ir`, cancun). If
verification is skipped or fails, it does **not** affect the deployment — you can verify
after the fact — but the source will remain unverified on the explorer until you do.

## After deploy

The contract is now live but holds no streams. Create streams by calling
`createStream(recipient, token, totalAmount, startTime, cliffTime, endTime, cancelable)`
after the sender has approved `totalAmount` of `token` to the deployed `StreamManager`.
Batch creation is available via `createStreamBatch(CreateParams[])`.
