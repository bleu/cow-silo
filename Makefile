.PHONY: build docs format test

build:
	forge build
	pnpm --filter @cow-silo/sdk build

docs:
	pnpm --filter @cow-silo/docs dev

format:
	forge fmt

test:
	forge test
	pnpm --filter @cow-silo/sdk test
