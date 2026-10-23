# QueryCraft SSH plugin

Optional libssh2-backed SSH transport for QueryCraft's MCP runtime.

- `src/ssh_plugin.c`: nonblocking SSH authentication and bounded command execution.
- Shared ABI: `QueryCraftPackage/Sources/CQueryCraftSSHPluginAPI/include/QueryCraftSSHPlugin.h`.
- Host services, credential access and authorization live in `QueryCraftFeature`.
- Static libssh2/OpenSSL are built from checksum-pinned sources and included only in the plugin.
- Successful plugin modules remain resident until process exit, including while timed-out system DNS workers finish.

Build with `python3 scripts/build-ssh-plugin.py`; see [SSH_MCP.md](../docs/SSH_MCP.md) for signing, installation, permissions, supported features and testing.

The plugin currently targets macOS 15+. Neither a desktop terminal nor SFTP MCP tools are part of this first implementation.
