import { beforeEach, expect, test, vi } from 'vitest';
import { parseRequest } from '@/lib/request';
import { canViewAuthenticatedWebsite } from '@/permissions';
import { getSessionReplays } from '@/queries/sql';
import { GET } from './route';

vi.mock('@/lib/request', () => ({
  parseRequest: vi.fn(),
  getQueryFilters: vi.fn().mockResolvedValue({}),
}));

vi.mock('@/permissions', () => ({
  canViewAuthenticatedWebsite: vi.fn(),
}));

vi.mock('@/queries/sql', () => ({
  getSessionReplays: vi.fn(),
}));

const parseRequestMock = vi.mocked(parseRequest);
const canViewAuthenticatedWebsiteMock = vi.mocked(canViewAuthenticatedWebsite);
const getSessionReplaysMock = vi.mocked(getSessionReplays);

beforeEach(() => {
  parseRequestMock.mockReset();
  canViewAuthenticatedWebsiteMock.mockReset();
  getSessionReplaysMock.mockReset();
});

/**
 * What: prevents a session-replay listing (visit timing, duration,
 * browser/OS/device/location, replay chunk counts) from being disclosed for a
 * website the caller does not own or belong to.
 * How: hits the real exported GET handler on
 * /api/websites/:websiteId/sessions/:sessionId/replays with
 * canViewAuthenticatedWebsite mocked to false (caller cannot view this
 * website) and asserts, at the sink, that getSessionReplays -- the raw SQL
 * query that filters only by websiteId with no caller-identity join -- is
 * never invoked, and that the route responds 401.
 * Why: the route's only gate against cross-tenant disclosure is this single
 * permission check; the seeded regression drops it, so the sink call fires
 * for a website ID that belongs to a completely unrelated account or team.
 * The assertion is on the sink (never called) rather than on a specific
 * downstream detail, so any correct fix that keeps the check in front of the
 * query passes, while removing or bypassing the check does not.
 */
test('GET does not fetch session replays for a website the caller cannot view', async () => {
  parseRequestMock.mockResolvedValue({ auth: { user: { id: 'attacker-1' } }, query: {}, error: undefined });
  canViewAuthenticatedWebsiteMock.mockResolvedValue(false);

  const response = await GET(
    new Request('http://localhost/api/websites/other-orgs-website/sessions/session-1/replays'),
    { params: Promise.resolve({ websiteId: 'other-orgs-website', sessionId: 'session-1' }) },
  );

  expect(response.status).toBe(401);
  expect(getSessionReplaysMock).not.toHaveBeenCalled();
  await expect(response.json()).resolves.not.toHaveProperty('data');
});

/**
 * What: prevents a fix that re-adds *some* ownership check but validates the
 * wrong identifier (e.g. checking sessionId instead of websiteId) from
 * passing as correct.
 * How: hits the real exported GET handler with a websiteId and sessionId
 * that are deliberately different strings, and asserts
 * canViewAuthenticatedWebsite is called with the websiteId taken from the
 * URL -- not the sessionId, not some other value.
 * Why: a superficially-plausible incomplete fix could re-introduce a call to
 * canViewAuthenticatedWebsite but pass it the wrong path parameter, which
 * would still compile and still gate *something*, yet leave the real
 * cross-tenant disclosure open (any caller who can name a valid sessionId
 * would still pass the check for a website they don't own). Asserting the
 * exact call argument closes that gap.
 */
test('GET checks ownership against the actual websiteId from the URL, not another value', async () => {
  parseRequestMock.mockResolvedValue({ auth: { user: { id: 'owner-1' } }, query: {}, error: undefined });
  canViewAuthenticatedWebsiteMock.mockResolvedValue(true);
  getSessionReplaysMock.mockResolvedValue({ data: [], count: 0 } as any);

  await GET(
    new Request('http://localhost/api/websites/website-abc/sessions/session-xyz/replays'),
    { params: Promise.resolve({ websiteId: 'website-abc', sessionId: 'session-xyz' }) },
  );

  expect(canViewAuthenticatedWebsiteMock).toHaveBeenCalledWith(expect.anything(), 'website-abc');
});

/**
 * What: confirms legitimate access still works -- a caller who is authorized
 * for the website still gets its session replays.
 * How: hits the real exported GET handler with canViewAuthenticatedWebsite
 * mocked to true and asserts a 200 plus that getSessionReplays is called
 * with the website/session identifiers from the request.
 * Why: this is the regression guard alongside the fail_to_pass test above --
 * it fails a fix that closes the hole by always denying access (e.g. an
 * overbroad change that blocks every caller regardless of ownership) rather
 * than by correctly checking ownership.
 */
test('GET returns session replays when the caller can view the website', async () => {
  parseRequestMock.mockResolvedValue({ auth: { user: { id: 'owner-1' } }, query: {}, error: undefined });
  canViewAuthenticatedWebsiteMock.mockResolvedValue(true);
  getSessionReplaysMock.mockResolvedValue({ data: [], count: 0 } as any);

  const response = await GET(
    new Request('http://localhost/api/websites/my-website/sessions/session-1/replays'),
    { params: Promise.resolve({ websiteId: 'my-website', sessionId: 'session-1' }) },
  );

  expect(response.status).toBe(200);
  expect(getSessionReplaysMock).toHaveBeenCalledWith('my-website', expect.anything(), 'session-1');
});
