/** Runs only inside the selected computer as its ordinary user. No deployment secrets enter it. */
export const computerInitializationProgram = String.raw`
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawn} from 'node:child_process';
const computerEnvironment=process.env;
const marker='# managed-computer-model-connection-v1';
const root=path.join(computerEnvironment.HOME,'.local/share/computer-model-connection');
const bin=path.join(computerEnvironment.HOME,'.local/bin');
async function directory(dir){
  const relative=path.relative(computerEnvironment.HOME,dir);
  if(relative.startsWith('..')||path.isAbsolute(relative))throw Error('unsafe_path');
  let current=computerEnvironment.HOME;
  for(const part of relative.split(path.sep).filter(Boolean)){
    current=path.join(current,part);
    try{await fs.mkdir(current,{mode:0o700})}catch(e){if(e.code!=='EEXIST')throw e}
    const info=await fs.lstat(current);
    if(!info.isDirectory()||info.isSymbolicLink()||info.uid!==process.getuid())throw Error('unsafe_path');
  }
}
async function write(file,content,mode=0o600){
  try{
    const info=await fs.lstat(file);
    if(!info.isFile()||info.isSymbolicLink()||info.uid!==process.getuid())throw Error('unsafe_path');
    if((info.mode&0o777)===mode&&await fs.readFile(file,'utf8')===content)return;
  }catch(e){if(e.code!=='ENOENT')throw e}
  const temp=file+'.'+process.pid+'.'+Math.random().toString(16).slice(2);
  try{await fs.writeFile(temp,content,{mode,flag:'wx'});await fs.rename(temp,file)}
  finally{await fs.rm(temp,{force:true})}
}
async function connection(grant){
  const response=await fetch(grant.url,{method:'POST',headers:{authorization:'Bearer '+grant.token},
    redirect:'error',signal:AbortSignal.timeout(20000)});
  if(!response.ok){await response.body?.cancel();const e=Error('connection_unavailable');e.status=response.status;throw e}
  const raw=await response.text();
  if(raw.length>256*1024)throw Error('invalid_connection');
  const value=JSON.parse(raw);
  const url=new URL(value.baseUrl);
  if(url.protocol!=='https:'||url.username||url.password||url.search||url.hash||
    typeof value.apiKey!=='string'||!value.apiKey||!value.defaults||!Array.isArray(value.modelIds))throw Error('invalid_connection');
  return value;
}
async function main(){
  if(computerEnvironment.COMPUTER_MODEL_INITIALIZATION&&!computerEnvironment.COMPUTER_MODEL_LAUNCH){
    const grant=JSON.parse(computerEnvironment.COMPUTER_MODEL_INITIALIZATION);
    await directory(root);await directory(bin);await directory(path.join(computerEnvironment.HOME,'shared'));
    await fs.chmod(root,0o700);
    // User launchers are never replaced. Other engines can still be initialized.
    const script=path.join(root,'run.mjs');
    const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
    const entries=['codex','claude','dsh'].map(engine=>({engine,file:path.join(bin,engine),
      content:'#!/bin/sh\n'+marker+'\nexec /usr/local/bin/node '+quote(script)+' '+engine+' "$@"\n'}));
    const managed=[];
    for(const entry of entries){
      try{const info=await fs.lstat(entry.file);if(!info.isFile()||info.isSymbolicLink()||info.uid!==process.getuid()||
        await fs.readFile(entry.file,'utf8')!==entry.content)continue}
      catch(e){if(e.code!=='ENOENT')throw e}
      managed.push(entry);
    }
    await write(path.join(root,'grant.json'),JSON.stringify(grant));
    await write(script,computerEnvironment.COMPUTER_MODEL_PROGRAM);
    for(const entry of managed)await write(entry.file,entry.content,0o700);
    return;
  }
  const [engine,...args]=process.argv.slice(computerEnvironment.COMPUTER_MODEL_LAUNCH?1:2);
  if(!['codex','claude','dsh'].includes(engine))throw Error('invalid_engine');
  const executable='/usr/local/bin/'+engine;
  // Local inspection and help do not need a model account or network.
  const inspect=args.some(arg=>['--help','--version','-V','-h'].includes(arg))||
    ['login','logout','auth'].includes(args[0]);
  let launch=args,childEnvironment={...computerEnvironment},overlay;
  for(const key of ['COMPUTER_MODEL_INITIALIZATION','COMPUTER_MODEL_PROGRAM','COMPUTER_MODEL_LAUNCH'])delete childEnvironment[key];
  if(!inspect){
    // A managed dispatch keeps its own authorization if another launcher refreshes the shared file.
    const grant=JSON.parse(computerEnvironment.COMPUTER_MODEL_LAUNCH?
      computerEnvironment.COMPUTER_MODEL_INITIALIZATION:await fs.readFile(path.join(root,'grant.json'),'utf8'));
    const config=await connection(grant),defaults=config.defaults;
    const selected=defaults[engine==='codex'?'responses':engine==='claude'?'anthropic-messages':'chat-completions'];
    if(typeof selected!=='string'||!config.modelIds.includes(selected))throw Error('model_unavailable');
    if(engine==='codex'){
      const model=defaults.responses;
      launch=['-c','model_provider="managed"','-c',
        'model_providers.managed={name="Model connection",base_url='+JSON.stringify(config.baseUrl)+',wire_api="responses",env_key="OPENAI_API_KEY"}',
        ...(model?['-c','model='+JSON.stringify(model)]:[]),...args];
      childEnvironment.OPENAI_API_KEY=config.apiKey;
    }else if(engine==='claude'){
      childEnvironment.ANTHROPIC_BASE_URL=config.baseUrl.replace(/\/v1\/?$/,'');
      childEnvironment.ANTHROPIC_AUTH_TOKEN=config.apiKey;
      delete childEnvironment.ANTHROPIC_API_KEY;
      for(const key of ['CLAUDE_CODE_USE_BEDROCK','CLAUDE_CODE_USE_VERTEX','CLAUDE_CODE_USE_FOUNDRY'])delete childEnvironment[key];
      const model=defaults['anthropic-messages'];
      if(model){childEnvironment.ANTHROPIC_MODEL=model;for(const tier of ['HAIKU','SONNET','OPUS'])childEnvironment['ANTHROPIC_DEFAULT_'+tier+'_MODEL']=model}
    }else{
      const model=defaults['chat-completions'];
      if(!model)throw Error('model_unavailable');
      const patch=[{id:'llm-pi-ai',config:{providers:{granted:{apiKeyEnv:'OPENAI_API_KEY',api:'openai-completions',
        baseURL:config.baseUrl,models:[{id:model}]}}}},{id:'agent-default-model',config:{provider:'granted',model}}];
      // Each process owns its overlay; concurrent launches cannot change a running profile.
      overlay=path.join(root,'overlay-'+process.pid+'.json');
      await write(overlay,JSON.stringify(patch));
      launch=['--patch',overlay,...args];childEnvironment.OPENAI_API_KEY=config.apiKey;
    }
  }
  try{
    const child=spawn(executable,launch,{env:childEnvironment,stdio:'inherit'});
    for(const signal of ['SIGINT','SIGTERM','SIGHUP'])process.on(signal,()=>child.kill(signal));
    process.exitCode=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve(code??(signal?128:1)))});
  }finally{if(overlay)await fs.rm(overlay,{force:true})}
}
main().catch(()=>{console.error('Model connection initialization failed.');process.exitCode=1});
`;
