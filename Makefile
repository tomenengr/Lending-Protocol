.PHONY: build test coverage fmt slither

build:
	forge build

test:
	forge test -vv

coverage:
	forge coverage

fmt:
	forge fmt

slither:
	slither .
