import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import { Vault } from "../generated/schema";

export let ZERO = BigInt.zero();

export function eventId(event: ethereum.Event): string {
  return event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
}

export function vaultWindowId(vault: Address, cycleId: BigInt): string {
  return vault.toHexString() + "-" + cycleId.toString();
}

export function modeName(mode: i32): string {
  if (mode == 0) return "PRESERVATION";
  if (mode == 1) return "CONSERVATION";
  if (mode == 2) return "NORMAL";
  return "UNKNOWN";
}

export function endpointId(endpoint: i32): string {
  return endpoint.toString();
}

export function getOrCreateVault(address: Address, timestamp: BigInt, blockNumber: BigInt, txHash: Bytes): Vault {
  let vault = Vault.load(address);
  if (vault == null) {
    vault = new Vault(address);
    vault.fundraisingToken = Bytes.empty();
    vault.currentCycleId = ZERO;
    vault.activeWindow = null;
    vault.totalEventsExecuted = ZERO;
    vault.totalUSDCDistributed = ZERO;
    vault.totalTokensBurned = ZERO;
    vault.latestTreasuryMode = null;
    vault.createdAt = timestamp;
    vault.createdBlock = blockNumber;
    vault.createdTx = txHash;
    vault.save();
  }
  return vault;
}
