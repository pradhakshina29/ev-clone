// Prints only whether each variable is set; never prints a value.
import { envVariableNames, optionalEnvVariableNames, parseEnv } from '../config/env.js';

let missing = 0;
for (const name of envVariableNames) {
  const value = process.env[name];
  const present = value !== undefined && value.trim() !== '' && !value.includes('REPLACE_ME');
  if (!present && optionalEnvVariableNames.includes(name)) {
    console.log(`${name}: not set (default used)`);
    continue;
  }
  if (!present) missing++;
  console.log(`${name}: ${present ? 'present' : 'missing'}`);
}

const result = parseEnv(process.env);
if (!result.ok) {
  console.log('\nProblems:');
  for (const problem of result.problems) console.log(`  - ${problem}`);
}
process.exit(missing === 0 && result.ok ? 0 : 1);
