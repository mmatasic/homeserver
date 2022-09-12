import sys
import subprocess
import os

def writeListToFile(location, filename, list, delimiter, mode):
    path = os.path.join(location, filename)
    with open(path, mode='wt', encoding='utf-8') as out:
        out.write(delimiter.join(list))
DELETE_CANDIDATES_FILENAME = "delete_candidates.txt"
playlistDir = os.path.dirname(sys.argv[1])
playlistFileName = os.path.basename(sys.argv[1])
os.chdir(playlistDir);
playlistFile= open(sys.argv[1])
count=0
outputLines = []
deleteCandidates = []

for file in playlistFile.readlines():
    resultLine = ""; 
    if not file or file.startswith("#"):
        outputLines.append(' '.join(file.split()))
    else: 
        fileName=os.path.basename(file)
        fileNameWithoutExt=os.path.splitext(fileName)[0]
        count +=1
        print("file {}: {}?".format(count, file.strip()))
        p = subprocess.Popen("fdfind -i " + "\"" + fileNameWithoutExt + "\"", stdout=subprocess.PIPE, shell=True, universal_newlines=True)
        stdout, stderr = p.communicate();
        results = stdout.splitlines()

        if len(results) == 1:
            outputLines.append(results[0])
            continue
        elif len(results) == 0:
            outputLines.append(' '.join(file.split()))
            continue

        for index, result in enumerate(results):
            print(str(index) + ":" + result)

        selectedIndex = 0
        while True: 
            selected = input("index to keep:")
            try:
                selectedIndex = int(selected)
            except ValueError:
                selectedIndex = 9999
                print("not valid selection")
            if selectedIndex < len(results):
                break;
        outputLines.append(results[selectedIndex])

        for index, result in enumerate(results):
            if index != selectedIndex:
                deleteCandidates.append(results[index])

writeListToFile(playlistDir, "new_" + playlistFileName, outputLines, '\n', 'wt')
writeListToFile(playlistDir, DELETE_CANDIDATES_FILENAME, deleteCandidates, '\n', 'at')

playlistFile.close()
