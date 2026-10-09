import {
  AllowListConfigured,
  HookDeployed,
  IntegrationUpdated
} from "../generated/IntegrationRegistry/IntegrationRegistry";
import { AllowListConfiguration, HookDeployment, IntegrationEndpoint } from "../generated/schema";
import { endpointId, eventId } from "./helpers";

export function handleAllowListConfigured(event: AllowListConfigured): void {
  let config = new AllowListConfiguration(eventId(event));
  config.endpoint = event.params.endpointType;
  config.allowedAddress = event.params.allowedAddress;
  config.allowed = event.params.allowed;
  config.timestamp = event.block.timestamp;
  config.blockNumber = event.block.number;
  config.transactionHash = event.transaction.hash;
  config.save();
}

export function handleIntegrationUpdated(event: IntegrationUpdated): void {
  let endpoint = new IntegrationEndpoint(endpointId(event.params.endpointType));
  endpoint.endpoint = event.params.endpointType;
  endpoint.currentAddress = event.params.newAddress;
  endpoint.updatedAt = event.block.timestamp;
  endpoint.updatedBlock = event.block.number;
  endpoint.save();
}

export function handleHookDeployed(event: HookDeployed): void {
  let deployment = new HookDeployment(eventId(event));
  deployment.hookAddress = event.params.hookAddress;
  deployment.timestamp = event.block.timestamp;
  deployment.blockNumber = event.block.number;
  deployment.transactionHash = event.transaction.hash;
  deployment.save();
}
