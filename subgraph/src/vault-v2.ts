import {
  Address,
  BigInt
} from "@graphprotocol/graph-ts";
import {
  DonationBurnExecuted,
  DonationEventExecuted,
  DonationEventRandomnessRequested,
  DonationExecutionFailed,
  DonationSlotEvaluated,
  DonationWindowStarted,
  FundsTransferredToNonProfit,
  TreasuryModeUpdated
} from "../generated/templates/VaultV2/VaultV2";
import {
  BeneficiaryTransfer,
  DonationBurn,
  DonationExecution,
  DonationFailure,
  DonationRandomnessRequest,
  DonationSlotEvaluation,
  DonationWindow,
  TreasuryModeUpdate
} from "../generated/schema";
import { eventId, getOrCreateVault, modeName, vaultWindowId, ZERO } from "./helpers";

function getWindow(vaultAddress: Address, cycleId: BigInt): DonationWindow | null {
  return DonationWindow.load(vaultWindowId(vaultAddress, cycleId));
}

export function handleDonationWindowStarted(event: DonationWindowStarted): void {
  let vault = getOrCreateVault(event.address, event.block.timestamp, event.block.number, event.transaction.hash);
  let windowId = vaultWindowId(event.address, event.params.cycleId);

  let window = new DonationWindow(windowId);
  window.vault = event.address;
  window.cycleId = event.params.cycleId;
  window.requestId = event.params.requestId;
  window.startsAt = event.params.startsAt;
  window.endsAt = event.params.endsAt;
  window.snapshotBalance = event.params.snapshotBalance;
  window.eventsExecuted = ZERO;
  window.save();

  vault.currentCycleId = event.params.cycleId;
  vault.activeWindow = windowId;
  vault.save();
}

export function handleDonationEventRandomnessRequested(event: DonationEventRandomnessRequested): void {
  let window = getWindow(event.address, event.params.cycleId);
  if (window == null) return;

  let request = new DonationRandomnessRequest(eventId(event));
  request.vault = event.address;
  request.window = window.id;
  request.cycleId = event.params.cycleId;
  request.eventIndex = event.params.eventIndex;
  request.requestId = event.params.requestId;
  request.requestedAt = event.params.requestedAt;
  request.blockNumber = event.block.number;
  request.transactionHash = event.transaction.hash;
  request.save();
}

export function handleDonationSlotEvaluated(event: DonationSlotEvaluated): void {
  let window = getWindow(event.address, event.params.cycleId);
  if (window == null) return;

  let evaluation = new DonationSlotEvaluation(eventId(event));
  evaluation.vault = event.address;
  evaluation.window = window.id;
  evaluation.cycleId = event.params.cycleId;
  evaluation.eventIndex = event.params.eventIndex;
  evaluation.selectedSlot = event.params.selectedSlot;
  evaluation.requestedSlot = event.params.requestedSlot;
  evaluation.executed = event.params.executed;
  evaluation.timestamp = event.block.timestamp;
  evaluation.blockNumber = event.block.number;
  evaluation.transactionHash = event.transaction.hash;
  evaluation.save();
}

export function handleDonationEventExecuted(event: DonationEventExecuted): void {
  let vault = getOrCreateVault(event.address, event.block.timestamp, event.block.number, event.transaction.hash);
  let window = getWindow(event.address, event.params.cycleId);
  if (window == null) return;

  let execution = new DonationExecution(eventId(event));
  execution.vault = event.address;
  execution.window = window.id;
  execution.cycleId = event.params.cycleId;
  execution.eventIndex = event.params.eventIndex;
  execution.amountIn = event.params.amountIn;
  execution.amountOut = event.params.amountOut;
  execution.timestamp = event.block.timestamp;
  execution.blockNumber = event.block.number;
  execution.transactionHash = event.transaction.hash;
  execution.save();

  window.eventsExecuted = window.eventsExecuted.plus(BigInt.fromI32(1));
  window.save();

  vault.totalEventsExecuted = vault.totalEventsExecuted.plus(BigInt.fromI32(1));
  vault.totalUSDCDistributed = vault.totalUSDCDistributed.plus(event.params.amountOut);
  vault.save();
}

export function handleDonationBurnExecuted(event: DonationBurnExecuted): void {
  let vault = getOrCreateVault(event.address, event.block.timestamp, event.block.number, event.transaction.hash);

  let burn = new DonationBurn(eventId(event));
  burn.vault = event.address;
  burn.cycleId = event.params.cycleId;
  burn.eventIndex = event.params.eventIndex;
  burn.burnAmount = event.params.burnAmount;
  burn.timestamp = event.block.timestamp;
  burn.blockNumber = event.block.number;
  burn.transactionHash = event.transaction.hash;
  burn.save();

  vault.totalTokensBurned = vault.totalTokensBurned.plus(event.params.burnAmount);
  vault.save();
}

export function handleTreasuryModeUpdated(event: TreasuryModeUpdated): void {
  let vault = getOrCreateVault(event.address, event.block.timestamp, event.block.number, event.transaction.hash);

  let update = new TreasuryModeUpdate(eventId(event));
  update.vault = event.address;
  update.previousMode = modeName(event.params.previousMode);
  update.newMode = modeName(event.params.newMode);
  update.treasuryPercentage = event.params.treasuryPercentage;
  update.timestamp = event.block.timestamp;
  update.blockNumber = event.block.number;
  update.transactionHash = event.transaction.hash;
  update.save();

  vault.latestTreasuryMode = update.newMode;
  vault.save();
}

export function handleFundsTransferredToNonProfit(event: FundsTransferredToNonProfit): void {
  let transfer = new BeneficiaryTransfer(eventId(event));
  transfer.vault = event.address;
  transfer.recipient = event.params.recipient;
  transfer.amount = event.params.amount;
  transfer.timestamp = event.block.timestamp;
  transfer.blockNumber = event.block.number;
  transfer.transactionHash = event.transaction.hash;
  transfer.save();
}

export function handleDonationExecutionFailed(event: DonationExecutionFailed): void {
  let vault = getOrCreateVault(event.address, event.block.timestamp, event.block.number, event.transaction.hash);
  if (vault.activeWindow == null) return;

  let failure = new DonationFailure(eventId(event));
  failure.vault = event.address;
  failure.window = vault.activeWindow!;
  failure.reason = event.params.reason;
  failure.timestamp = event.block.timestamp;
  failure.blockNumber = event.block.number;
  failure.transactionHash = event.transaction.hash;
  failure.save();
}
