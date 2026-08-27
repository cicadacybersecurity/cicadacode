# Pi operator cheatsheet

This worker operates a Raspberry Pi over SSH. It has NO direct access to the Pi's filesystem - everything happens by running remote commands through the local shell.

## Connection
- Host: 100.98.156.107   User: cicadaserver
- Run anything on the Pi with:  ssh -i "C:\Users\David\.ssh\pi_key" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 cicadaserver@100.98.156.107 "<remote command>"
- Copy files TO the Pi:    scp -i "C:\Users\David\.ssh\pi_key" <localfile> cicadaserver@100.98.156.107:<remote-path>
- Copy files FROM the Pi:  scp -i "C:\Users\David\.ssh\pi_key" cicadaserver@100.98.156.107:<remote-path> <localfile>

## Rules
- Verify before modifying: inspect remotely first, then change.
- Never run destructive commands (rm -rf, mkfs, dd, shutdown, reboot, service stops) unless the user's current prompt explicitly asked for exactly that.
- Prefer idempotent commands; report what each command returned, honestly.
- If a command fails, show the error and propose the fix - do not retry blindly more than once.
- For long-running remote work use nohup ... & and poll - do not hold sessions open.
