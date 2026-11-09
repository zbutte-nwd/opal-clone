.PHONY: test test-contracts test-swift test-server test-admin ios-project ios-build server-dev vectors bootstrap-mac

test: test-contracts test-swift test-server test-admin

test-contracts:
	python3 contracts/tools/validate.py
	python3 contracts/tools/ref_engine.py contracts/engine-vectors.json

test-swift:
	cd ios/Packages/TetherCore && swift test

test-server:
	cd server && (npm ci || npm install) && npm run typecheck && npm test

test-admin:
	cd admin && (npm ci || npm install) && npm run build && npm test

ios-project:
	cd ios && xcodegen generate

ios-build: ios-project
	cd ios && xcodebuild -project Tether.xcodeproj -scheme Tether -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

server-dev:
	./scripts/dev-server.sh

vectors:
	python3 contracts/tools/gen_vectors.py

bootstrap-mac:
	./scripts/bootstrap-mac.sh

.PHONY: e2e
e2e: ## cross-stack smoke test: server + device API + Swift engine decode
	./scripts/e2e-smoke.sh
