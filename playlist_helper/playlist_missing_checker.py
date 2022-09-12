import sys
import subprocess
import glob, os
from os.path import exists
import re

def writeListToFile(location, filename, list, delimiter, mode):
    print("list:")
    print(list)
    print(delimiter)
    print(mode)
    path = os.path.join(location, filename)
    with open(path, mode='wt', encoding='utf-8') as out:
        out.write(delimiter.join(list))

#def writeListToFile(filepath, list, delimiter, mode):
#   with open(filepath, mode='wt', encoding='utf-8') as out:
#        out.write(delimiter.join(list))

def findAlternative(filename):
    print("searching for: " + filename)
    p = subprocess.Popen("fdfind -iF " + "\"" + filename + "\"", stdout=subprocess.PIPE, shell=True, universal_newlines=True)
    stdout, stderr = p.communicate();
    results = stdout.splitlines()
    if len(results) > 100:
        return ""
    if not results:
        return ""
    if len(results) == 1:
        print("auto replacing with:" + results[0])
        return results[0]
    results.append("")
    for index, result in enumerate(results):
        print(str(index) + ": " + result)
    selectedIndex = 0
    while True: 
        selected = input("index to replace the missing song (last index - keep current):")
        try:
           selectedIndex = int(selected)
        except ValueError:
            selectedIndex = 9999
            print("not valid selection")
        if selectedIndex < len(results):
                 break;
    return results[selectedIndex]

playlistDir = sys.argv[1]
os.chdir(playlistDir);
playlists = []
for file in glob.glob("./*.m3u8"):
    playlists.append(file)

for pfile in playlists:
    playlistFile= open(pfile)
    playlistFileName = os.path.basename(pfile)
    outputLines = [] 
    print("----- playlist file: " + playlistFileName)
    for file in playlistFile.readlines():
        file = file.strip()
        if not file or file.startswith("#"):
            print("comment or meta line:" + file)
            outputLines.append(' '.join(file.split()))
            continue
        elif not exists(file.strip()):
            print("file is missing: " + file)
            fileName=os.path.basename(file)
            fileNameWithoutExt=os.path.splitext(fileName)[0]
            splitNames = fileNameWithoutExt.split("-")
            songName = splitNames[len(splitNames)-1] 
            #removing parenthesis
            songName = re.sub("\(.*?\)|\[.*?\]","",songName)
            alternative =  findAlternative(songName.strip())
            if alternative:
                outputLines.append(alternative.strip())
            else:
                print("didn't find alternative")
                outputLines.append(' '.join(file.split()))
        else:
            print("OK - " + file)
            outputLines.append(' '.join(file.split()))
            continue
    playlistFile.close()
    # backup
    os.rename(pfile.strip(), pfile.strip()+ ".bak")
    writeListToFile(playlistDir, playlistFileName, outputLines, '\n', 'wt')
    print("done: " + playlistFileName)
print("DONE")