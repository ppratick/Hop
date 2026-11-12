#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/hop-tests.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
python3 - "$PROJECT_DIR" "$TEST_TMP" <<'PY'
import pathlib,sys
project=pathlib.Path(sys.argv[1]); temp=pathlib.Path(sys.argv[2])
s=(project/'Sources/Hop/main.swift').read_text()
head,tail=s.split('if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--run-service" {',1)
runner='if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--run-service" {'+tail.split('} else if CommandLine.arguments.contains("--scan") {',1)[0]+'} else {\n Task { @MainActor in await integrationTest() }\n NSApplication.shared.setActivationPolicy(.prohibited); NSApplication.shared.run()\n}\n'
(temp/'main.swift').write_text(head+'\n'+(project/'Sources/Hop/ProjectOverview.swift').read_text()+'\n'+(project/'Sources/Hop/ProjectPlatforms.swift').read_text()+'\n'+(project/'Sources/Hop/Deployment.swift').read_text()+'\n'+(project/'Sources/Hop/MacDeployment.swift').read_text()+'\n'+(project/'Sources/Hop/Devices.swift').read_text()+'\n'+(project/'Sources/Hop/Interface.swift').read_text()+'\n'+(project/'Sources/Hop/GitViews.swift').read_text()+'\n'+(project/'Sources/Hop/GitSync.swift').read_text()+'\n'+(project/'Sources/Hop/TerminalService.swift').read_text()+'\n'+(project/'Sources/Hop/Organization.swift').read_text()+'\n'+(project/'Sources/Hop/OpenAIUsage.swift').read_text()+'\n'+(project/'Tests/Integration.swift').read_text()+'\n'+runner)
PY
xcrun swiftc -swift-version 5 -module-cache-path "$TEST_TMP/modules" -framework AppKit -framework SwiftUI "$TEST_TMP/main.swift" -o "$TEST_TMP/Hop-tests"
HOP_TEST_ROOT="$TEST_TMP/fixtures" "$TEST_TMP/Hop-tests"
