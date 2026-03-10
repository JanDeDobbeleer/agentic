# Agentic

```text
   ___    ____  ____  _  __  ______  ____  ______
  / _ |  / ___// __/ / |/ / /_  __/ /  _/ / ___/
 / __ | / (_ // _/  /    /   / /   _/ /  / /__
/_/ |_| \___//___/ /_/|_/   /_/   /___/  \___/

    ⚡ Skills & Agents — Powered by APM ⚡
```

Personal [APM][apm](Agent Package Manager) repository containing reusable skills and agent
definitions for AI-powered coding assistants.

## What is APM?

[APM][apm] is a package manager for AI agent skills and definitions. It allows you to define,
share, and consume structured instructions that guide AI agents in specific tasks — from writing
conventional commits to following language-specific coding standards.

## Usage

Install the [APM CLI][apm], then add any skill from this repository:

```shell
apm install JanDeDobbeleer/agentic/skills/golang
```

## Quality Checks

Pull requests are validated with:

- [markdownlint](https://github.com/DavidAnson/markdownlint) — enforces consistent markdown formatting
- [Vale](https://vale.sh) — prose linting with [ai-tells](https://github.com/tbhb/vale-ai-tells)
  and [agentic](https://github.com/HeyItsGilbert/vale-agentic) style packages

## License

[MIT](LICENSE)

[apm]: https://github.com/microsoft/apm
