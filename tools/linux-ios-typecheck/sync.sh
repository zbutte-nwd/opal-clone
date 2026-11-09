#!/usr/bin/env bash
# Copies the iOS-only Swift sources (TetherKit, 4 extensions, non-SwiftUI app files) into this
# package, where they compile against hand-written shims of the Apple frameworks (Sources/<Framework>/Shim.swift,
# mirroring real iOS 18 SDK signatures). Catches wrong labels/types/isolation on Linux. SwiftUI views are NOT covered.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; R="$HERE/../../ios"; S="$HERE/Sources"
mkdir -p "$S/TetherKitCheck" "$S/Extensions" "$S/AppCore"
rm -f "$S"/TetherKitCheck/*.swift "$S"/Extensions/*.swift "$S"/AppCore/*.swift
for f in "$R"/Packages/TetherCore/Sources/TetherKit/*.swift; do
  b=$(basename "$f"); [ "$b" = ReportContexts.swift ] && continue
  sed '1s/^#if os(iOS).*$/#if true/' "$f" > "$S/TetherKitCheck/$b"
done
for f in "$R"/Extensions/TetherMonitor/*.swift "$R"/Extensions/TetherPush/*.swift "$R"/Extensions/TetherShieldAction/*.swift "$R"/Extensions/TetherShieldConfig/*.swift; do
  sed 's/^import TetherKit$/import TetherKitCheck/' "$f" > "$S/Extensions/$(basename "$f")"
done
for f in App/AppModel.swift App/DeepLinkRouter.swift App/AppDelegate.swift Platform/PlatformServices.swift Platform/LivePlatformServices.swift Platform/StubPlatformServices.swift Components/Formatters.swift Features/Rules/RuleDraft.swift; do
  sed 's/^import TetherKit$/import TetherKitCheck/' "$R/App/Sources/$f" > "$S/AppCore/$(basename "$f")"
  if [ "$(basename "$f")" = Formatters.swift ]; then sed -i.bak "1s/^/import os\n/" "$S/AppCore/Formatters.swift" && rm -f "$S/AppCore/Formatters.swift.bak"; fi
done
