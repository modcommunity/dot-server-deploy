This is the content directory. It contains all the game assets and content that can be dynamically loaded by the server at runtime.

## Features
- Users with the `change` permission can change the server's content/game to the directory set in here.
    - This automatically has the clients connected download and mount the new content/game directory while connecting them to the server.
- Each content/game directory has its own subfolder here and that's what is used to identify the content/game when changing or loading it on the server.
- Any content in the `global/` directory is loaded by every "game" instance on the server.
- The `global/` directory is useful for assets or scripts that need to be available across all content/game instances.
- When changing the content/game directory, the server will automatically handle the loading and unloading of the relevant content, ensuring a seamless experience for connected clients.