/**
 * The published bia release (tools/release.sh) ships a raw disk image per
 * architecture. bia-os.json names it; the arm64 file is bia-arm64.img.xz.
 */

const LATEST = "https://api.github.com/repos/zond80/bia/releases/latest";
const RELEASE_PAGE = "https://github.com/zond80/bia/releases/latest";
const MANIFEST = "bia-os.json";
const ARM64_IMAGE = "bia-arm64.img.xz";

export interface BiaRelease {
  tag: string;
  version: string;
  url: string;
}

export async function lookupBiaRelease(): Promise<BiaRelease> {
  let resp: Response;
  try {
    resp = await fetch(LATEST, {
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": "ClawHome",
      },
      signal: AbortSignal.timeout(20_000),
    });
  } catch (err) {
    throw new Error(`Could not reach the bia release (${err instanceof Error ? err.message : String(err)})`);
  }
  if (resp.status === 404) throw new Error("No bia release is published yet.");
  if (!resp.ok) throw new Error(`GitHub returned ${resp.status} for the bia release.`);
  const body = (await resp.json()) as {
    tag_name?: string;
    name?: string;
    assets?: { name?: string }[];
  };
  const names = new Set((body.assets ?? []).map((asset) => asset.name).filter((name): name is string => !!name));
  if (!names.has(MANIFEST) || !names.has(ARM64_IMAGE)) {
    throw new Error("The latest bia release has no arm64 system.");
  }
  const tag = body.tag_name || "";
  const version = tag.replace(/^v/, "") || (body.name || "").replace(/^bia\s+/i, "") || tag;
  return { tag, version, url: RELEASE_PAGE };
}
