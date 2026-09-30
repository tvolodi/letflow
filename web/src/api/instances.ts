import { client } from './client'
import type {
  ProcessInstance,
  StartInstanceRequest,
  CursorPage,
  InstanceStatus,
  EventRecord,
  TimelinePage,
  InstancePinsResponse,
  RebindPinsRequest,
  RebindPinsResponse,
} from '@/types/api'

export const instancesApi = {
  list: (params?: {
    status?: InstanceStatus[]
    definition_id?: string
    cursor?: string
    page_size?: number
  }) =>
    client.get<CursorPage<ProcessInstance>>('/api/v1/instances', {
      ...params,
      status: params?.status?.join(','),
    } as Record<string, unknown>),

  get: (id: string) =>
    client.get<ProcessInstance>(`/api/v1/instances/${id}`),

  start: (body: StartInstanceRequest) =>
    client.post<ProcessInstance>('/api/v1/instances', body),

  cancel: (id: string, reason?: string) =>
    client.post<void>(`/api/v1/instances/${id}/cancel`, { reason }),

  events: (
    id: string,
    params?: {
      after_seq?: number
      before_seq?: number
      limit?: number
      event_type?: string
      from?: string
      to?: string
    },
  ) =>
    client.get<EventRecord[]>(`/api/v1/instances/${id}/history`, params as Record<string, unknown>),

  timeline: (id: string, params?: { cursor?: string; page_size?: number }) =>
    client.get<TimelinePage>(`/api/v1/instances/${id}/timeline`, params as Record<string, unknown>),

  reconstruct: (id: string) =>
    client.get<ProcessInstance>(`/api/v1/instances/${id}/reconstruct`),

  // REQ-399: already-shipped route (REQ-080) — pure read of
  // PinResolver.reconstruct_effective_pins/2, no query params.
  getPins: (id: string) =>
    client.get<InstancePinsResponse>(`/api/v1/instances/${id}/pins`),

  // REQ-432: already-shipped route (REQ-078/PIN-05). Idempotency-Key is a
  // header, not a body field; the caller decides its lifetime.
  rebindPins: (id: string, body: RebindPinsRequest, idempotencyKey: string) =>
    client.postWithHeaders<RebindPinsResponse>(
      `/api/v1/instances/${id}/rebind-pins`,
      body,
      { 'Idempotency-Key': idempotencyKey },
    ),
}
