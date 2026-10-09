# EvolveNP Subgraph

This subgraph indexes the core EvolveNP protocol events:

- `Factory`
  - `FundraisingVaultCreated`
  - `LiquidityPoolCreated`
  - `PoolCreationFailed`
- `VaultV2` dynamic templates
  - `DonationWindowStarted`
  - `DonationEventRandomnessRequested`
  - `DonationSlotEvaluated`
  - `DonationEventExecuted`
  - `DonationBurnExecuted`
  - `TreasuryModeUpdated`
  - `FundsTransferredToNonProfit`
  - `DonationExecutionFailed`
- `EmergencyManager`
  - emergency arming/activation/exit
  - reporter configuration
  - endpoint failures
- `IntegrationRegistry`
  - allowlist updates
  - integration endpoint updates
  - shared hook deployment

## Network Templates

This subgraph follows the same template-driven layout used by `auto-forward-safe-module`:

- `subgraph.template.yaml` contains the shared manifest.
- `networks/<chain>.json` contains chain-specific contract addresses and start blocks.
- `subgraph.yaml` is generated from the template before codegen, build, or deploy.

The current supported chain is Sepolia, using the latest addresses in:

```txt
deployments/11155111/latest.json
```

If you redeploy, update these source addresses in `networks/sepolia.json`:

- `Factory`
- `EmergencyManager`
- `IntegrationRegistry`

`VaultV2` contracts are indexed dynamically when the factory emits `FundraisingVaultCreated`.

To support another chain, add a new `networks/<chain>.json` file with this shape and add matching npm scripts:

```json
{
  "network": "sepolia",
  "Factory": {
    "address": "0x...",
    "startBlock": 0
  },
  "EmergencyManager": {
    "address": "0x...",
    "startBlock": 0
  },
  "IntegrationRegistry": {
    "address": "0x...",
    "startBlock": 0
  }
}
```

## Install

```bash
cd subgraph
npm install
```

## Generate Types

```bash
npm run codegen
```

## Build

```bash
npm run build:sepolia
```

## Deploy

Set `DEPLOY_KEY`, update the deployment target in `package.json` if needed, then run:

```bash
npm run deploy:sepolia
```

## Notes

- The ABIs in `subgraph/abis` are intentionally event-only ABIs for indexing.
- `VaultV2` totals are aggregated from events, so historical accuracy depends on indexing from a block before the relevant event emissions.
- `startBlock` is currently `0` because the deployment JSON does not include block numbers. For faster indexing, replace it with each contract deployment block in the relevant `networks/<chain>.json` file.
