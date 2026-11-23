#!/usr/bin/env bash
# Proves the bundle-contract checker actually fails when the contract breaks.
#
# A checker proved once by hand-editing is proved for one afternoon: the next change
# to the checker can be the one that makes it print OK for everything. So the six
# mutations below are committed and re-run on every CI build, on a throwaway copy of
# the tree — never on the working copy, so a crash halfway cannot leave the repo
# mutated.
#
# Exit codes: 0 all mutations caught, 1 something slipped through, 2 the harness
# itself could not run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/scripts" "${WORK}/HealthCollector" "${WORK}/HealthCollector.xcodeproj"
cp "${ROOT}/scripts/check-bundle-contract.py" "${WORK}/scripts/"
# Копируется всё дерево, а не только файлы в корне: иначе новая подпапка (UI/)
# исчезает из копии, checker видит ссылки на несуществующие файлы и «базовое
# дерево» падает раньше мутаций.
cp -R "${ROOT}/HealthCollector/." "${WORK}/HealthCollector/"
cp "${ROOT}/HealthCollector.xcodeproj/project.pbxproj" "${WORK}/HealthCollector.xcodeproj/"

check() { python3 "${WORK}/scripts/check-bundle-contract.py" >/dev/null 2>&1; echo $?; }

restore() {
    cp "${ROOT}/HealthCollector/HealthCollector.entitlements" "${WORK}/HealthCollector/"
    cp "${ROOT}/HealthCollector/Info.plist" "${WORK}/HealthCollector/"
    cp "${ROOT}/HealthCollector.xcodeproj/project.pbxproj" "${WORK}/HealthCollector.xcodeproj/"
    rm -f "${WORK}/HealthCollector/Leak.swift"
}

failures=0

if [[ "$(check)" != "0" ]]; then
    echo "FAIL: базовое дерево не проходит проверку — мутации нечего доказывать"
    exit 2
fi

expect_fail() {
    local label="$1"
    local code
    code="$(check)"
    if [[ "${code}" == "0" ]]; then
        echo "FAIL: не поймана мутация — ${label}"
        failures=$((failures + 1))
    else
        echo "ok   ловит: ${label}"
    fi
    restore
}

# 1. A missing capability: the app would ask the profile for less than it needs.
python3 - "${WORK}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "HealthCollector" / "HealthCollector.entitlements"
t = p.read_text().replace("<key>com.apple.developer.healthkit.background-delivery</key>\n\t<true/>\n", "")
p.write_text(t)
PY
expect_fail "пропал background-delivery"

# 2. An extra entitlement: a permission the profile is not known to grant.
python3 - "${WORK}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "HealthCollector" / "HealthCollector.entitlements"
t = p.read_text().replace("</dict>", "\t<key>com.apple.developer.icloud-services</key>\n\t<array><string>CloudKit</string></array>\n</dict>")
p.write_text(t)
PY
expect_fail "лишний entitlement"

# 3. A background mode that implies the wrong mechanism.
python3 - "${WORK}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "HealthCollector" / "Info.plist"
t = p.read_text().replace("<key>UILaunchScreen</key>", "<key>UIBackgroundModes</key>\n\t<array><string>fetch</string></array>\n\t<key>UILaunchScreen</key>")
p.write_text(t)
PY
expect_fail "UIBackgroundModes в Info.plist"

# 4. A source file on disk that never reaches the compiler.
printf 'import Foundation\n' > "${WORK}/HealthCollector/Leak.swift"
expect_fail "незарегистрированный .swift"

# 5. A build setting pointing at nothing.
python3 - "${WORK}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "HealthCollector.xcodeproj" / "project.pbxproj"
t = p.read_text().replace("INFOPLIST_FILE = HealthCollector/Info.plist;", "INFOPLIST_FILE = HealthCollector/Missing.plist;")
p.write_text(t)
PY
expect_fail "INFOPLIST_FILE на несуществующий файл"

# 6. A reference to an object the project does not define.
python3 - "${WORK}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "HealthCollector.xcodeproj" / "project.pbxproj"
t = p.read_text().replace("productReference = C0DEC0DE0000000000000014", "productReference = C0DEC0DE00000000000000FF")
p.write_text(t)
PY
expect_fail "ссылка на неопределённый объект"

if [[ "${failures}" -ne 0 ]]; then
    echo "ИТОГ: ${failures} мутаций не поймано"
    exit 1
fi
echo "ИТОГ: все мутации пойманы"
