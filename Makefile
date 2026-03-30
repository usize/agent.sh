PREFIX   := $(HOME)/.local
BIN      := $(PREFIX)/bin
SKILL_DIR := $(HOME)/.claude/commands

.PHONY: install uninstall

install:
	@mkdir -p $(BIN)
	@cp agent.sh $(BIN)/agent.sh
	@chmod +x $(BIN)/agent.sh
	@echo "installed agent.sh to $(BIN)/agent.sh"

	@mkdir -p $(SKILL_DIR)
	@cp .claude/commands/orchestrate.md $(SKILL_DIR)/orchestrate.md
	@echo "installed /orchestrate command to $(SKILL_DIR)/orchestrate.md"

	@if ! echo "$$PATH" | tr ':' '\n' | grep -qx "$(BIN)"; then \
		echo ""; \
		echo "\033[33m$(BIN) is not in your PATH. Add to your shell profile:\033[0m"; \
		echo "  export PATH=\"$(BIN):\$$PATH\""; \
	fi

	@echo ""
	@echo "source agent.sh in your shell profile for the 'agents' function:"
	@echo "  echo 'source $(BIN)/agent.sh' >> ~/.zshrc"

uninstall:
	@rm -f $(BIN)/agent.sh
	@echo "removed $(BIN)/agent.sh"
	@rm -f $(SKILL_DIR)/orchestrate.md
	@echo "removed $(SKILL_DIR)/orchestrate.md"
