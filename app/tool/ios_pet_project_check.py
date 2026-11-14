#!/usr/bin/env python3
"""Linux structural check for the pet extension; does not compile Swift/Dart.

Validates the Xcode object graph and shared-source/embedding/signing contracts.
Run from any directory: python3 app/tool/ios_pet_project_check.py
"""
from pathlib import Path
import re, plistlib, xml.etree.ElementTree as ET
root=Path(__file__).resolve().parents[2]; ios=root/'app/ios'
# Parse the actual OpenStep dictionary/array grammar, with comments and strings.
s=(ios/'Runner.xcodeproj/project.pbxproj').read_text()
tokens=re.findall(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+',s,re.S)
tokens=[t for t in tokens if not t.startswith(('/*','//'))]; i=0
def take(t=None):
 global i
 v=tokens[i];i+=1
 assert t is None or t==v,(i,t,v)
 return v
def value():
 if tokens[i]=='{':
  take('{'); result={}
  while tokens[i]!='}':
   k=take(); take('='); assert k not in result,k
   result[k]=value();take(';')
  take('}');return result
 if tokens[i]=='(':
  take('(');result=[]
  while tokens[i]!=')':
   result.append(value())
   if tokens[i]!=')':take(',')
  take(')');return result
 return take().strip('"')
data=value();assert i==len(tokens)
objects=data['objects']; ids=set(re.findall(r'\b[A-F0-9]{24}\b',s));assert ids==set(objects)
project=objects[data['rootObject']]
targets={objects[k]['name']:objects[k] for k in project['targets']}
app=targets['Runner'];widget=targets['PetLiveActivity']
assert widget['productType']=='com.apple.product-type.app-extension'
assert any(objects[d]['target'] in project['targets'] and objects[objects[d]['target']]['name']=='PetLiveActivity' for d in app['dependencies'])
phases=[objects[k] for k in app['buildPhases']]
assert any(p['isa']=='PBXCopyFilesBuildPhase' and p['dstSubfolderSpec']=='13' and any(objects[b]['fileRef']==widget['productReference'] for b in p['files']) for p in phases)
for target, expected in [(app,{'Runner/PetLiveActivityPlugin.swift','Shared/PetActivityAttributes.swift'}),(widget,{'PetLiveActivity/PetLiveActivity.swift','Shared/PetActivityAttributes.swift'})]:
 sources={objects[objects[b]['fileRef']]['path'] for k in target['buildPhases'] if objects[k]['isa']=='PBXSourcesBuildPhase' for b in objects[k]['files']}
 assert expected<=sources,(sources,expected)
 for path in expected:assert (ios/path).is_file()
 configs=objects[target['buildConfigurationList']]['buildConfigurations'];assert len(configs)==3
 for c in configs:
  settings=objects[c]['buildSettings']; ent=plistlib.loads((ios/settings['CODE_SIGN_ENTITLEMENTS']).read_bytes())
  assert ent['com.apple.security.application-groups']==['group.io.github.ccch1mneyyy.dshApp']
  assert settings.get('DEVELOPMENT_TEAM','')==''
  assert not settings.get('PROVISIONING_PROFILE_SPECIFIER')
  if target is widget:
   assert settings['IPHONEOS_DEPLOYMENT_TARGET']=='16.2'
   assert settings['APPLICATION_EXTENSION_API_ONLY']=='YES'
   assert settings['CODE_SIGN_IDENTITY']==''
for p in ios.rglob('*'):
 if 'ephemeral' in p.parts:continue
 if p.suffix in ['.plist','.entitlements','.xcsettings']:plistlib.loads(p.read_bytes())
 elif p.suffix in ['.storyboard','.xcscheme','.xcworkspacedata']:ET.parse(p)
info=plistlib.loads((ios/'Runner/Info.plist').read_bytes());assert info['NSSupportsLiveActivities']
assert info['FlutterDeepLinkingEnabled'] is False
assert info['CFBundleURLTypes'][0]['CFBundleURLSchemes']==['dshgo']
for p in [*(p for p in ios.rglob('*.swift') if 'ephemeral' not in p.parts),root/'app/lib/notify/pet_art_stage.dart',root/'app/lib/notify/pet_live_activity.dart',root/'app/test/notify/pet_art_stage_test.dart',root/'app/test/notify/pet_live_activity_test.dart',root/'app/lib/state/live_activity_state.dart']:
 for n,line in enumerate(p.read_text().splitlines(),1): assert line==line.rstrip(),(p,n)
print('PASS: OpenStep parse; PBX references, target dependency/embed, shared source membership, all configuration entitlements/version/deployment/signing settings, plist/XML, new-source whitespace')
