SHELL := /bin/bash
MISE ?= mise
ELIXIR_DIR := orchestrator/elixir

.PHONY: install setup toolchain hooks \
	ts-install elixir-install \
	fmt fmt-ts fmt-elixir \
	lint lint-ts lint-elixir \
	typecheck test test-ts test-elixir \
	check check-ts check-elixir

install: setup

setup: toolchain ts-install elixir-install hooks

toolchain:
	$(MISE) install

ts-install:
	$(MISE) exec -- corepack enable
	$(MISE) exec -- pnpm install

elixir-install:
	cd $(ELIXIR_DIR) && $(MISE) exec -- mix deps.get

hooks:
	$(MISE) exec -- pnpm exec lefthook install

fmt: fmt-ts fmt-elixir

fmt-ts:
	$(MISE) exec -- pnpm run fmt

fmt-elixir:
	cd $(ELIXIR_DIR) && $(MISE) exec -- mix format

lint: lint-ts lint-elixir

lint-ts:
	$(MISE) exec -- pnpm run lint:ts

lint-elixir:
	cd $(ELIXIR_DIR) && $(MISE) exec -- mix lint

typecheck:
	$(MISE) exec -- pnpm run typecheck

test: test-ts test-elixir

test-ts:
	$(MISE) exec -- pnpm run test

test-elixir:
	cd $(ELIXIR_DIR) && MIX_ENV=test $(MISE) exec -- mix test

check: check-ts check-elixir

check-ts:
	$(MISE) exec -- pnpm run check:ts

check-elixir:
	cd $(ELIXIR_DIR) && $(MISE) exec -- mix format --check-formatted
	cd $(ELIXIR_DIR) && $(MISE) exec -- mix compile --warnings-as-errors
	cd $(ELIXIR_DIR) && $(MISE) exec -- mix lint
	cd $(ELIXIR_DIR) && $(MISE) exec -- mix dialyzer --format dialyxir
	cd $(ELIXIR_DIR) && MIX_ENV=test $(MISE) exec -- mix test
