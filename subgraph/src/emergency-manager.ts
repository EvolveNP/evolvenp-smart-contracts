import {
  EmergencyActivated,
  EmergencyArmed,
  EmergencyExited,
  EndpointFailureRecorded,
  ReporterConfigured
} from "../generated/EmergencyManager/EmergencyManager";
import {
  EmergencyActivationEvent,
  EmergencyArmedEvent,
  EmergencyExitEvent,
  EmergencyManagerState,
  EndpointFailureEvent,
  ReporterConfiguration
} from "../generated/schema";
import { eventId, ZERO } from "./helpers";

function getState(): EmergencyManagerState {
  let state = EmergencyManagerState.load("global");
  if (state == null) {
    state = new EmergencyManagerState("global");
    state.armedReasonFlags = ZERO;
    state.emergencyActive = false;
    state.emergencyExpiresAt = ZERO;
    state.lastUpdatedAt = ZERO;
    state.lastUpdatedBlock = ZERO;
  }
  return state;
}

export function handleEmergencyArmed(event: EmergencyArmed): void {
  let armed = new EmergencyArmedEvent(eventId(event));
  armed.triggerFlags = event.params.triggerFlags;
  armed.consecutiveQuoteFailures = event.params.consecutiveQuoteFailures;
  armed.consecutiveSwapFailures = event.params.consecutiveSwapFailures;
  armed.timestamp = event.block.timestamp;
  armed.blockNumber = event.block.number;
  armed.transactionHash = event.transaction.hash;
  armed.save();

  let state = getState();
  state.armedReasonFlags = event.params.triggerFlags;
  state.emergencyActive = false;
  state.lastUpdatedAt = event.block.timestamp;
  state.lastUpdatedBlock = event.block.number;
  state.save();
}

export function handleEmergencyActivated(event: EmergencyActivated): void {
  let activation = new EmergencyActivationEvent(eventId(event));
  activation.expiresAt = event.params.expiresAt;
  activation.timestamp = event.block.timestamp;
  activation.blockNumber = event.block.number;
  activation.transactionHash = event.transaction.hash;
  activation.save();

  let state = getState();
  state.emergencyActive = true;
  state.emergencyExpiresAt = event.params.expiresAt;
  state.lastUpdatedAt = event.block.timestamp;
  state.lastUpdatedBlock = event.block.number;
  state.save();
}

export function handleEmergencyExited(event: EmergencyExited): void {
  let exit = new EmergencyExitEvent(eventId(event));
  exit.timestamp = event.block.timestamp;
  exit.blockNumber = event.block.number;
  exit.transactionHash = event.transaction.hash;
  exit.save();

  let state = getState();
  state.armedReasonFlags = ZERO;
  state.emergencyActive = false;
  state.emergencyExpiresAt = ZERO;
  state.lastUpdatedAt = event.block.timestamp;
  state.lastUpdatedBlock = event.block.number;
  state.save();
}

export function handleReporterConfigured(event: ReporterConfigured): void {
  let reporter = new ReporterConfiguration(eventId(event));
  reporter.reporter = event.params.reporter;
  reporter.allowed = event.params.allowed;
  reporter.timestamp = event.block.timestamp;
  reporter.blockNumber = event.block.number;
  reporter.transactionHash = event.transaction.hash;
  reporter.save();
}

export function handleEndpointFailureRecorded(event: EndpointFailureRecorded): void {
  let failure = new EndpointFailureEvent(eventId(event));
  failure.endpoint = event.params.endpoint;
  failure.timestamp = event.block.timestamp;
  failure.blockNumber = event.block.number;
  failure.transactionHash = event.transaction.hash;
  failure.save();
}
