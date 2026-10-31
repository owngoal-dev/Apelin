// Open in Apelin: reads `url` and an optional `branch` from this page's
// address, checks them as Apelin does (ApelinLink.isRepositoryAddress and
// isBranchName in Widgets/Shared/ApelinLink.swift), and offers the
// apelin://import link Apelin asks about. Nothing read here is ever put into
// the page as markup: text goes in as text, and the link is built from the
// checked values, each URL-encoded.
"use strict";

const MAX_ADDRESS = 2048;
const MAX_BRANCH = 255;

function utf8Length(text) {
  return new TextEncoder().encode(text).length;
}

// https:// in lower case with a host and a path, spelt in printable ASCII
// (RFC 3986's characters but ? and #), no user or password, well-formed
// escapes, no . or .. component, and no control or format character once
// decoded.
function isRepositoryAddress(address) {
  if (address.length === 0 || address.length > MAX_ADDRESS) return false;
  if (!/^[A-Za-z0-9\-._~:/[\]@!$&'()*+,;=%]+$/.test(address)) return false;
  if (/%(?![0-9A-Fa-f]{2})/.test(address)) return false;
  const match = /^https:\/\/([^/]*)(\/.*)?$/.exec(address);
  if (!match) return false;
  const authority = match[1];
  // a public host name, spelt as it is shown: no escape, no address
  // literal, no name only a local network resolves; a port of 1-65535
  const hostAndPort = /^([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?$/.exec(authority);
  if (!hostAndPort || !isPublicHostName(hostAndPort[1])) return false;
  if (hostAndPort[2] !== undefined && !(Number(hostAndPort[2]) >= 1 && Number(hostAndPort[2]) <= 65535)) return false;
  const path = match[2] || "";
  const names = path.split("/").filter((name) => name.length > 0);
  if (names.length === 0 || names.some((name) => name === "." || name === "..")) return false;
  let decoded;
  try {
    decoded = decodeURIComponent(path);
  } catch {
    return false;
  }
  return !/[\p{Cc}\p{Cf}]/u.test(decoded);
}

// A name the public DNS answers for: letters, digits, - and dots, at least
// one dot, no address literal, none of the suffixes only a local network
// resolves.
function isPublicHostName(host) {
  let name = host.toLowerCase();
  if (name.endsWith(".")) name = name.slice(0, -1);
  const labels = name.split(".");
  if (labels.length < 2 || name.length > 253) return false;
  if (!labels.every((label) => /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) return false;
  if (labels.every((label) => /^[0-9]+$/.test(label) || label.startsWith("0x"))) return false;
  const local = ["local", "lan", "internal", "localhost", "localdomain", "intranet", "home.arpa", "corp", "test", "invalid"];
  return !local.some((suffix) => name === suffix || name.endsWith("." + suffix));
}

// A branch git takes (check-ref-format --branch), bounded, shown as it reads.
function isBranchName(name) {
  if (name.length === 0 || utf8Length(name) > MAX_BRANCH) return false;
  if (name.startsWith("-") || name === "HEAD" || name === "@") return false;
  if (name.startsWith("/") || name.endsWith("/") || name.endsWith(".")) return false;
  if (name.includes("//") || name.includes("..") || name.includes("@{")) return false;
  if (/[\p{Cc}\p{Cf}\p{Co}\p{Cn}\p{Z}\s~^:?*[\\]/u.test(name)) return false;
  // drawn blank: the fillers, the braille blank, noncharacters
  if (/[\u2800\u3164\u115F\u1160\uFFA0\uFFFE\uFFFF]/u.test(name)) return false;
  return name.split("/").every((part) => !part.startsWith(".") && !part.endsWith(".lock"));
}

// `url` and `branch` each at most once, as Apelin reads them; anything else
// in the address is ignored. Null when the link names nothing to import.
function readRequest(search) {
  // read as Apelin reads them: `+` is a plus, not a space, and a value
  // whose escapes do not decode to text names nothing
  const addresses = [];
  const branches = [];
  for (const pair of search.replace(/^\?/, "").split("&")) {
    if (pair === "") continue;
    const at = pair.indexOf("=");
    const name = at < 0 ? pair : pair.slice(0, at);
    if (name !== "url" && name !== "branch") continue;
    let value;
    try {
      value = decodeURIComponent(at < 0 ? "" : pair.slice(at + 1));
    } catch {
      return null;
    }
    (name === "url" ? addresses : branches).push(value);
  }
  if (addresses.length !== 1 || branches.length > 1 || !isRepositoryAddress(addresses[0])) return null;
  const branch = branches.length === 1 && branches[0] !== "" ? branches[0] : null;
  if (branch !== null && !isBranchName(branch)) return null;
  return { address: addresses[0], branch };
}

function importLink(request) {
  let link = "apelin://import?url=" + encodeURIComponent(request.address);
  if (request.branch !== null) link += "&branch=" + encodeURIComponent(request.branch);
  return link;
}

function pageLink(request) {
  const page = new URL(".", location.href);
  let link = page.href + "?url=" + encodeURIComponent(request.address);
  if (request.branch !== null) link += "&branch=" + encodeURIComponent(request.branch);
  return link;
}

function markdown(request) {
  const badge = new URL("badge.svg", location.href).href;
  return "[![Open in Apelin](" + badge + ")](" + pageLink(request) + ")";
}

async function copy(text, status, done) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    // an older browser: copy from a selected field instead
    const field = document.createElement("textarea");
    field.value = text;
    field.setAttribute("readonly", "");
    field.style.position = "fixed";
    field.style.opacity = "0";
    document.body.appendChild(field);
    field.select();
    const copied = document.execCommand("copy");
    field.remove();
    if (!copied) {
      status.textContent = "Copying is not available here. Select the text and copy it instead.";
      return;
    }
  }
  status.textContent = done;
}

const request = readRequest(location.search);
const status = document.getElementById("status");
const example = request || { address: "https://github.com/owner/repository", branch: null };
document.getElementById("markdown").textContent = markdown(example);
document.getElementById("copy-markdown").addEventListener("click", () => {
  copy(markdown(example), document.getElementById("markdown-status"), "Markdown copied.");
});

if (request === null) {
  // a bare visit says what the page is for; a malformed link says so
  const bare = location.search === "";
  document.getElementById("about").hidden = !bare;
  document.getElementById("invalid").hidden = bare;
} else {
  document.getElementById("repository").hidden = false;
  document.getElementById("address").textContent = request.address;
  document.getElementById("branch").textContent = request.branch === null ? "Default branch" : request.branch;
  const open = document.getElementById("open");
  open.href = importLink(request);
  open.addEventListener("click", () => {
    // still here a while after the tap: Apelin did not open
    setTimeout(() => {
      if (document.visibilityState === "visible" && document.hasFocus()) {
        status.textContent = "If Apelin did not open, install it as described below, or copy the address and import it in Apelin with New Project.";
      }
    }, 2500);
  });
  document.getElementById("copy-address").addEventListener("click", () => {
    copy(request.address, status, "Repository address copied.");
  });
}
