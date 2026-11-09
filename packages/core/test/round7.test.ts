// 0.6 round 7: SHARED_IDENTITY_HOSTS, from protocol/shared-identity-hosts.json.
// The list is the same as the file's, and every vector holds.
import { describe, it, expect } from 'vitest';
import shared from '../../../protocol/shared-identity-hosts.json';
import { Allowlist, SHARED_IDENTITY_HOSTS, isSharedIdentityHost, nativeBlockHosts } from '../src';

describe('SHARED_IDENTITY_HOSTS', () => {
  it('matches protocol/shared-identity-hosts.json', () => {
    expect([...SHARED_IDENTITY_HOSTS]).toEqual(shared.hosts);
  });

  it('every "excluded" vector holds', () => {
    const a = new Allowlist();
    const bad = shared.vectors.excluded.filter((v) => isSharedIdentityHost(v.host, a.hostsFor(v.store)!) !== v.excluded);
    expect(bad).toEqual([]);
  });

  it('every "blockHosts" vector holds, signed widening included', () => {
    for (const v of shared.vectors.blockHosts as Array<{ store: string; widen?: { hosts?: string[]; authHosts?: string[] }; blockHosts: string[] }>) {
      const a = new Allowlist();
      if (v.widen) a.widen({ v: 1, kind: 'allowlist', exp: 0, stores: { [v.store]: v.widen } });
      expect([v.store, nativeBlockHosts(a.hostsFor(v.store)!)]).toEqual([v.store, v.blockHosts]);
    }
  });

  it('a tenant label must equal a store name, not contain it', () => {
    const s = new Allowlist().hostsFor('safeway')!;
    expect(isSharedIdentityHost('albertsons.okta.com', s)).toBe(false);
    expect(isSharedIdentityHost('albertsonsx.okta.com', s)).toBe(true);
    expect(isSharedIdentityHost('xalbertsons.okta.com', s)).toBe(true);
  });
});
