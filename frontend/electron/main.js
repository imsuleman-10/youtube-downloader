import { app, BrowserWindow } from 'electron';
import path from 'path';
import { spawn } from 'child_process';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const iconPath = path.join(__dirname, '../public/samtube.png');

let mainWindow;
let pythonProcess;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    title: 'SamTube',
    icon: iconPath,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  // Check if we are running in development mode
  const isDev = process.env.NODE_ENV === 'development';

  if (isDev) {
    mainWindow.loadURL('http://localhost:5173');
    // mainWindow.webContents.openDevTools();
  } else {
    mainWindow.loadFile(path.join(__dirname, '../dist/index.html'));
  }
}

function startBackend() {
  const isDev = process.env.NODE_ENV === 'development';
  const rootDir = isDev 
    ? path.join(__dirname, '../../')
    : process.resourcesPath;

  const backendDir = path.join(rootDir, 'backend');
  
  // Spawn python directly instead of using the bat file
  // This avoids issues with spaces in paths when using shell: true with bat files
  // Ensure Deno is in PATH for yt-dlp JS challenges
  const env = { ...process.env };
  const denoPath = path.join(process.env.USERPROFILE || process.env.HOME || '', '.deno', 'bin');
  env.PATH = env.PATH ? `${env.PATH};${denoPath}` : denoPath;

  pythonProcess = spawn('python', ['-m', 'uvicorn', 'app.main:app', '--host', '0.0.0.0', '--port', '8000'], { 
    cwd: backendDir,
    windowsHide: true,
    env
  });

  pythonProcess.stdout.on('data', (data) => {
    console.log(`backend: ${data}`);
  });

  pythonProcess.stderr.on('data', (data) => {
    console.error(`backend error: ${data}`);
  });

  pythonProcess.on('close', (code) => {
    console.log(`backend process exited with code ${code}`);
  });
}

app.whenReady().then(() => {
  startBackend();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('quit', () => {
  if (pythonProcess) {
    // Kill the python process tree on Windows
    spawn("taskkill", ["/pid", pythonProcess.pid, '/f', '/t']);
  }
});
