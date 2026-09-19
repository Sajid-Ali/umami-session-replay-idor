import { beforeEach, expect, test, vi } from 'vitest';
import { getQueryFilters, parseRequest } from '@/lib/request';
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
const getQueryFiltersMock = vi.mocked(getQueryFilters);
const canViewAuthenticatedWebsiteMock = vi.mocked(canViewAuthenticatedWebsite);
const getSessionReplaysMock = vi.mocked(getSessionReplays);

beforeEach(() => {
  parseRequestMock.mockReset();
  getQueryFiltersMock.mockReset().mockResolvedValue({});
  canViewAuthenticatedWebsiteMock.mockReset();
  getSessionReplaysMock.mockReset();
});

/**
 * Confirms this listing endpoint (all replays for a website, no sessionId
 * filter) refuses to return replay data for a website the caller cannot
 * view: canViewAuthenticatedWebsite mocked false yields a 401 and the
 * getSessionReplays query is never invoked.
 */
test('GET does not fetch session replays for a website the caller cannot view', async () => {
  parseRequestMock.mockResolvedValue({ auth: { user: { id: 'attacker-1' } }, query: {}, error: undefined });
  canViewAuthenticatedWebsiteMock.mockResolvedValue(false);

  const response = await GET(
    new Request('http://localhost/api/websites/other-orgs-website/replays'),
    { params: Promise.resolve({ websiteId: 'other-orgs-website' }) },
  );

  expect(response.status).toBe(401);
  expect(getSessionReplaysMock).not.toHaveBeenCalled();
});

/**
 * Confirms legitimate access still works: canViewAuthenticatedWebsite mocked
 * true yields a 200 and getSessionReplays is called with the website id and
 * filters.
 */
test('GET returns session replays when the caller can view the website', async () => {
  parseRequestMock.mockResolvedValue({ auth: { user: { id: 'owner-1' } }, query: {}, error: undefined });
  canViewAuthenticatedWebsiteMock.mockResolvedValue(true);
  getSessionReplaysMock.mockResolvedValue({ data: [], count: 0 } as any);

  const response = await GET(
    new Request('http://localhost/api/websites/my-website/replays'),
    { params: Promise.resolve({ websiteId: 'my-website' }) },
  );

  expect(response.status).toBe(200);
  expect(getSessionReplaysMock).toHaveBeenCalledWith('my-website', expect.anything());
});
