import os
import re
import uuid

project_path = 'App.xcodeproj/project.pbxproj'
if not os.path.exists(project_path):
    print(f"Error: {project_path} not found.")
    exit(1)

with open(project_path, 'r') as f:
    content = f.read()

# 定义需要添加的文件列表
new_files = [
    'WebViewContainer.swift',
    'MainTabView.swift',
    'JSBridgeManager.swift',
    'QRCodeScannerView.swift',
    'ImagePickerView.swift',
    'IncomingCallView.swift',
    'NotificationBannerView.swift'
]

# 为每个文件生成唯一的 ID
def generate_id():
    return str(uuid.uuid4()).replace('-', '')[:24].upper()

# 1. 检查并添加 PBXFileReference
file_ref_section = re.search(r'/\* Begin PBXFileReference section \*/(.*?)/\* End PBXFileReference section \*/', content, re.DOTALL)
if file_ref_section:
    section_content = file_ref_section.group(1)
    for file in new_files:
        if file not in section_content:
            file_id = generate_id()
            new_ref = f'\t\t{file_id} /* {file} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {file}; sourceTree = "<group>"; }};\n'
            content = content.replace('/* End PBXFileReference section */', new_ref + '/* End PBXFileReference section */')
            print(f"Added FileReference for {file}")

# 2. 检查并添加到 PBXGroup (App 组)
group_section = re.search(r'504EC3061FED79650016851F /\* App \*/ = \{.*?children = \((.*?)\);.*?sourceTree = "<group>";', content, re.DOTALL)
if group_section:
    children_content = group_section.group(1)
    for file in new_files:
        if file not in children_content:
            # 找到该文件的 file_id
            file_id_match = re.search(r'(\w+) /\* ' + re.escape(file) + r' \*/ = {isa = PBXFileReference', content)
            if file_id_match:
                file_id = file_id_match.group(1)
                new_child = f'\t\t\t\t\t{file_id} /* {file} */,\n'
                content = content.replace(children_content, children_content + new_child)
                children_content += new_child
                print(f"Added {file} to App group")

# 3. 检查并添加 PBXBuildFile
build_file_section = re.search(r'/\* Begin PBXBuildFile section \*/(.*?)/\* End PBXBuildFile section \*/', content, re.DOTALL)
if build_file_section:
    section_content = build_file_section.group(1)
    for file in new_files:
        if f'/* {file} in Sources */' not in section_content:
            # 找到该文件的 file_id
            file_id_match = re.search(r'(\w+) /\* ' + re.escape(file) + r' \*/ = {isa = PBXFileReference', content)
            if file_id_match:
                file_id = file_id_match.group(1)
                build_id = generate_id()
                new_build = f'\t\t{build_id} /* {file} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {file} */; }};\n'
                content = content.replace('/* End PBXBuildFile section */', new_build + '/* End PBXBuildFile section */')
                print(f"Added BuildFile for {file}")

# 4. 检查并添加到 PBXSourcesBuildPhase
sources_phase = re.search(r'504EC3001FED79650016851F /\* Sources \*/ = \{.*?files = \((.*?)\);', content, re.DOTALL)
if sources_phase:
    files_content = sources_phase.group(1)
    for file in new_files:
        if f'/* {file} in Sources */' not in files_content:
            # 找到该文件的 build_id
            build_id_match = re.search(r'(\w+) /\* ' + re.escape(file) + r' in Sources \*/ = {isa = PBXBuildFile', content)
            if build_id_match:
                build_id = build_id_match.group(1)
                new_source = f'\t\t\t\t\t{build_id} /* {file} in Sources */,\n'
                content = content.replace(files_content, files_content + new_source)
                files_content += new_source
                print(f"Added {file} to Sources build phase")

with open(project_path, 'w') as f:
    f.write(content)
print("Project file fixed successfully.")
