import fs from 'node:fs';
import path from 'node:path';

export function lockProfile(profile, io = fs) {
  if (!io.existsSync(profile) || !io.statSync(profile).isDirectory())
    throw new Error('The --profile directory must already exist and be signed in by the owner');
  const lock = path.join(profile, '.portal-capture.lock');
  let descriptor;
  try { descriptor = io.openSync(lock, 'wx'); }
  catch (error) {
    if (error.code === 'EEXIST') throw new Error('This profile is locked by another capture run. Do not start a second browser or automatically break the lock.');
    throw error;
  }
  io.writeFileSync(descriptor, JSON.stringify({ pid: process.pid, started_at_utc: new Date().toISOString() }));
  io.closeSync(descriptor);
  let released = false;
  return () => {
    if (!released) { io.unlinkSync(lock); released = true; }
  };
}
