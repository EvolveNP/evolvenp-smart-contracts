import { LiquidityPoolCreated, FundraisingVaultCreated, PoolCreationFailed } from "../generated/Factory/Factory";
import { VaultV2 as VaultV2Template } from "../generated/templates";
import { LiquidityPool, PoolCreationFailure, Protocol } from "../generated/schema";
import { eventId, getOrCreateVault } from "./helpers";

export function handleFundraisingVaultCreated(event: FundraisingVaultCreated): void {
  let protocol = new Protocol(event.params.fundraisingToken);
  protocol.fundraisingToken = event.params.fundraisingToken;
  protocol.vault = event.params.vault;
  protocol.factory = event.address;
  protocol.poolCreated = false;
  protocol.pool = null;
  protocol.createdAt = event.block.timestamp;
  protocol.createdBlock = event.block.number;
  protocol.createdTx = event.transaction.hash;
  protocol.save();

  let vault = getOrCreateVault(event.params.vault, event.block.timestamp, event.block.number, event.transaction.hash);
  vault.fundraisingToken = event.params.fundraisingToken;
  vault.protocol = event.params.fundraisingToken;
  vault.save();

  VaultV2Template.create(event.params.vault);
}

export function handleLiquidityPoolCreated(event: LiquidityPoolCreated): void {
  let poolId = event.params.owner.toHexString();
  let pool = new LiquidityPool(poolId);
  pool.fundraisingToken = event.params.owner;
  pool.protocol = event.params.owner;
  pool.currency0 = event.params.currency0;
  pool.currency1 = event.params.currency1;
  pool.owner = event.params.owner;
  pool.createdAt = event.block.timestamp;
  pool.createdBlock = event.block.number;
  pool.createdTx = event.transaction.hash;
  pool.save();

  let protocol = Protocol.load(event.params.owner);
  if (protocol != null) {
    protocol.poolCreated = true;
    protocol.pool = poolId;
    protocol.save();
  }
}

export function handlePoolCreationFailed(event: PoolCreationFailed): void {
  let failure = new PoolCreationFailure(eventId(event));
  failure.fundraisingToken = event.params.fundraisingToken;
  failure.reason = event.params.reason;
  failure.endpoint = event.params.endpoint;
  failure.timestamp = event.block.timestamp;
  failure.blockNumber = event.block.number;
  failure.transactionHash = event.transaction.hash;
  failure.save();
}
