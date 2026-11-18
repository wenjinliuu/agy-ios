export interface RelayRpcRequest {
  kind: "rpc_request";
  reqId: string;
  method: string;
  path: string;
  query: string;
  body?: string;
}

export interface RelayRpcResponse {
  kind: "rpc_response";
  reqId: string;
  status: number;
  contentType?: string;
  body: string;
}

export interface RelayClientWsEnvelope {
  kind: "client_ws";
  payload: unknown;
}

export interface RelayServerWsEnvelope {
  kind: "server_ws";
  payload: unknown;
}

export interface RelayVpsHello {
  kind: "vps_hello";
  bridgeVersion?: string;
  hostname?: string;
}

export type RelayWireMessage =
  | RelayRpcRequest
  | RelayRpcResponse
  | RelayClientWsEnvelope
  | RelayServerWsEnvelope
  | RelayVpsHello;
