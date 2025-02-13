# DStack Pre-launch Script Example

This directory provides an example of a pre-launch script for the DStack Application. Introduced in Dstack v0.3.5 (as detailed in [#94](https://github.com/Dstack-TEE/dstack/pull/94)), this feature allows the application to perform preliminary setup steps before initiating Docker Compose. The pre-launch script's content is specified in the `pre_launch_script` section of the `app-compose.json` file. The `prelaunch.sh` script demonstrates how to manage container initialization and configure the environment prior to launching your application.
