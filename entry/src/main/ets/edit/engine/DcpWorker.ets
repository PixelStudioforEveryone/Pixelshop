import { RenderTables, renderDcpPlan } from './DcpCpu';
import { ParsedDcpProfile, parseDcpProfile } from '../utils/DcpProfileParser';

@Concurrent
export function parseDcpProfileTask(data: ArrayBuffer, model: string, name: string, fixed: boolean): ParsedDcpProfile {
  return parseDcpProfile(data, model, name, fixed);
}

@Concurrent
export function processDcp(linear: ArrayBuffer, tables: RenderTables): ArrayBuffer {
  return renderDcpPlan(linear, tables);
}
