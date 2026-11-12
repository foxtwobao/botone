/** Runs as the computer user; validate the opened descriptor against the actual workspace. */
export const workspaceFileProgram = `
import os, sys, stat, base64, json
workspace, home, file = sys.argv[1:]
root = os.path.realpath(workspace)
assert root.startswith(os.path.realpath(home) + os.sep), 'file_outside_workspace'
relative = file[len('/workspace/'):] if file.startswith('/workspace/') else file
if os.path.isabs(relative):
    relative = os.path.relpath(relative, root)
assert not os.path.isabs(relative) and '..' not in relative.split('/'), 'invalid_file_path'
fd = os.open(os.path.join(root, relative), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
with os.fdopen(fd, 'rb') as source:
    actual = os.path.realpath('/proc/self/fd/' + str(source.fileno()))
    assert actual.startswith(root + os.sep), 'file_outside_workspace'
    assert stat.S_ISREG(os.fstat(source.fileno()).st_mode), 'invalid_workspace_file'
    data = source.read(1024 * 1024 + 1)
    assert len(data) <= 1024 * 1024, 'workspace_file_limit'
    print(json.dumps({'name': os.path.basename(relative), 'content': base64.b64encode(data).decode()}))
`;
