import fs from "node:fs";
import path from "node:path";

const root = path.resolve(process.argv[2] ?? "");
const failures = [];
const warnings = [];

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    failures.push(`읽을 수 없는 JSON: ${path.relative(root, file)}`);
    return null;
  }
}

const packageRoot = fs.existsSync(path.join(root, "node_modules", "kordoc", "package.json"))
  ? path.join(root, "node_modules", "kordoc")
  : root;
const kordoc = readJson(path.join(packageRoot, "package.json"));
if (!kordoc || kordoc.name !== "kordoc" || kordoc.version !== "4.13.1") {
  failures.push("Kordoc 4.13.1 패키지가 아닙니다.");
}
for (const required of ["LICENSE", "NOTICE"]) {
  if (!fs.existsSync(path.join(packageRoot, required))) failures.push(`Kordoc 고지 누락: ${required}`);
}
const thirdPartyDirectory = path.join(packageRoot, "THIRD_PARTY");
if (!fs.existsSync(thirdPartyDirectory) || !fs.statSync(thirdPartyDirectory).isDirectory()) {
  failures.push("Kordoc 고지 누락: THIRD_PARTY");
}
const lockfile = readJson(path.join(root, "package-lock.json"));
if (!lockfile) failures.push("package-lock.json이 없습니다.");
if (lockfile?.packages?.["node_modules/kordoc"]?.version !== "4.13.1") {
  failures.push("package-lock.json의 Kordoc 버전이 4.13.1이 아닙니다.");
}
if (kordoc?.license !== "MIT") failures.push("Kordoc 자체 라이선스가 MIT로 명시되지 않았습니다.");
const kordocNotice = fs.existsSync(path.join(packageRoot, "NOTICE"))
  ? fs.readFileSync(path.join(packageRoot, "NOTICE"), "utf8")
  : "";
if (/AGPL/i.test(kordocNotice)) {
  warnings.push("Kordoc NOTICE에 AGPL 계열 수식 OCR 고지가 있습니다. 이번 앱은 OCR/PDF 선택 의존성을 설치·호출하지 않지만, 상용 배포 전 법무 검토가 필요합니다.");
}

const optional = Object.keys(kordoc?.optionalDependencies ?? {});

const allowed = new Set(["MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Python-2.0", "Zlib"]);
const visited = new Set();
const packages = [];
const rootReal = fs.existsSync(root) ? fs.realpathSync(root) : root;

function licenseText(pkg) {
  if (typeof pkg.license === "string") return pkg.license;
  if (Array.isArray(pkg.licenses)) return pkg.licenses.map((item) => item.type ?? "").join(" AND ");
  return "";
}

function licenseAllowed(expression) {
  const atoms = expression
    .replace(/[()]/g, "")
    .split(/\s+(?:AND|OR)\s+/i)
    .map((item) => item.trim())
    .filter(Boolean);
  if (!atoms.length || atoms.some((item) => /AGPL/i.test(item))) return false;
  if (atoms.some((item) => /^GPL/i.test(item))) {
    return /\bMIT\b/i.test(expression) && /\bOR\b/i.test(expression);
  }
  return atoms.every((item) => allowed.has(item));
}

function visitModules(directory) {
  if (!fs.existsSync(directory)) return;
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    if (entry.name.startsWith("@")) {
      visitModules(path.join(directory, entry.name));
      continue;
    }
    const packageDirectory = path.join(directory, entry.name);
    const packageFile = path.join(packageDirectory, "package.json");
    if (!fs.existsSync(packageFile)) continue;
    let real;
    try {
      real = fs.realpathSync(packageDirectory);
    } catch {
      failures.push(`의존성 경로를 확인할 수 없습니다: ${path.relative(root, packageDirectory)}`);
      continue;
    }
    if (real !== rootReal && !real.startsWith(`${rootReal}${path.sep}`)) {
      failures.push(`node_modules 밖을 가리키는 의존성 링크: ${path.relative(root, packageDirectory)}`);
      continue;
    }
    if (visited.has(real)) continue;
    visited.add(real);
    const pkg = readJson(packageFile);
    if (!pkg) continue;
    const expression = licenseText(pkg);
    if (!licenseAllowed(expression)) failures.push(`허용되지 않은 라이선스: ${pkg.name}@${pkg.version} (${expression || "미기재"})`);
    const legalFiles = fs.readdirSync(packageDirectory).filter((name) => /^(license|licence|copying|notice)([-_.]|$)/i.test(name));
    if (!legalFiles.length) warnings.push(`라이선스 파일 없이 package.json metadata만 있는 의존성: ${pkg.name}@${pkg.version}`);
    packages.push({ name: pkg.name, version: pkg.version, license: expression });
    visitModules(path.join(packageDirectory, "node_modules"));
  }
}

visitModules(path.join(root, "node_modules"));
if (!packages.length) failures.push("Kordoc production node_modules가 비어 있습니다.");
for (const name of optional) {
  if (packages.some((item) => item.name === name)) failures.push(`선택적 의존성이 설치되어 있습니다: ${name}`);
}

if (failures.length) {
  for (const failure of failures) console.error(`[kordoc-runtime] ${failure}`);
  process.exit(1);
}

const expressions = [...new Set(packages.map((item) => item.license))].sort();
for (const warning of warnings) console.error(`[kordoc-runtime] 검토 경고: ${warning}`);
console.log(`[kordoc-runtime] Kordoc ${kordoc.version} 검증 통과: ${packages.length}개 패키지, 라이선스 ${expressions.join(", ")}`);
