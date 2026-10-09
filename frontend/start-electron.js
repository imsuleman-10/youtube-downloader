import { spawn } from 'child_process';
import waitOn from 'wait-on';

console.log("Waiting for Vite server on port 5173...");
waitOn({ resources: ['tcp:5173'] })
  .then(() => {
    console.log("Vite server is ready. Starting Electron...");
    const child = spawn('npm', ['run', 'electron:start'], { 
      shell: true, 
      stdio: 'inherit' 
    });
    child.on('error', err => console.error(err));
  })
  .catch(err => {
    console.error("Error waiting for Vite server:", err);
  });
