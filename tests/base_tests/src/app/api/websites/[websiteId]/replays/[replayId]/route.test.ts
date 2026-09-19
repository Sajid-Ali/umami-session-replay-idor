import { beforeEach, expect, test, vi } from 'vitest';
import { parseRequest } from '@/lib/request';
import { canViewAuthenticatedWebsite } from '@/permissions';
import { getReplayChunks } from '@/queries/sql';
import { GET } from './route';

vi.mock('@/lib/request', () => ({
  parseRequest: vi.fn(),
}));

vi.mock('@/permissions', () => ({
  canViewAuthenticatedWebsite: vi.fn(),
}));

vi.mock('@/queries/sql', () => ({
  getReplayChunks: vi.fn(),
}));

const parseRequestMock = vi.mocked(parseRequest);
const canViewAuthenticatedWebsiteMock = vi.mocked(canViewAuthenticatedWebsite);
const getReplayChunksMock = vi.mocked(getReplayChunks);

beforeEach(() => {
  parseRequestMock.mockReset();
  canViewAuthenticatedWebsiteMock.mockReset();
  getReplayChunksMock.mockReset();
});

/**
 * Confirms this route refuses to return replay chunk data for a website the
 * caller cannot view: canViewAuthenticatedWebsite mocked false yields a 401
 * and the getReplayChunks query is never invoked.
 */
test('GET does not fetch replay chunks for a website the caller cannot view', async () => {
  parseRequestMock.mockResolvedValue({ auth: { user: { id: 'attacker-1' } }, error: undefined });
  canViewAuthenticatedWebsiteMock.mockResolvedValue(false);

  const response = await GET(
    new Request('http://localhost/api/websites/other-orgs-website/replays/replay-1'),
    { params: Promise.resolve({ websiteId: 'other-orgs-website', replayId: 'replay-1' }) },
  );

  expect(response.status).toBe(401);
  expect(getReplayChunksMock).not.toHaveBeenCalled();
});

/**
 * Confirms legitimate access still works: canViewAuthenticatedWebsite mocked
 * true yields a 200 and getReplayChunks is called with the website id,
 * replay id, and options.
 */
test('GET returns replay chunks when the caller can view the website', async () => {
  parseRequestMock.mockResolvedValue({ auth: { user: { id: 'owner-1' } }, error: undefined });
  canViewAuthenticatedWebsiteMock.mockResolvedValue(true);
  getReplayChunksMock.mockResolvedValue([]);

  const response = await GET(
    new Request('http://localhost/api/websites/my-website/replays/replay-1'),
    { params: Promise.resolve({ websiteId: 'my-website', replayId: 'replay-1' }) },
  );

  expect(response.status).toBe(200);
  expect(getReplayChunksMock).toHaveBeenCalledWith(
    'my-website',
    'replay-1',
    expect.anything(),
  );
});
