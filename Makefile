.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:[^#]*## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":[^#]*## "}; {printf "  %-20s %s\n", $$1, $$2}'

.PHONY: install-hooks
install-hooks: ## Install pre-commit hooks
	pre-commit install

.PHONY: owners
owners: ## Render OWNERS files and the ownership table from hyperfleet/docs/owners.yaml
	python3 hack/owners/gen_owners.py render

.PHONY: verify-owners
verify-owners: ## Check hyperfleet/docs/owners.md is in sync with owners.yaml
	python3 hack/owners/gen_owners.py check
