#include <iostream>
#include <fstream>
#include <regex>
#include <string>
#include <vector>
#include <map>
#include <filesystem>
#include <windows.h>
#include <chrono>
#include <thread>
#include <sstream>
#include <cstdlib>
#include <algorithm>

namespace fs = std::filesystem;

// Structure to hold instance details
struct Instance {
    std::string identifier;   // e.g., "Pie64_1"
    std::string displayName;  // e.g., "Pie 64-bit Instance 1"
    std::string adbPort;      // e.g., "5555"
};

// Function prototypes
std::string getExecutableDir();
std::string getRegistryValue(HKEY hkey, const std::string& subkey, const std::string& valueName);
std::string getBlueStacksInstallDir();
std::string getBlueStacksDataDir();
void terminateBlueStacksProcesses();
void enableAdbInConfig(const std::string& confFile);
std::string ensureAdbAvailable(const std::string& bluestacksInstallDir);
std::string getApkPath();
std::vector<Instance> parseInstances(const std::string& confFile);
std::vector<int> selectInstances(const std::vector<Instance>& instances);
bool connectToInstance(const std::string& adbExe, const Instance& inst, std::string& device, int maxAttempts = 3);
bool installApkOnInstance(const std::string& adbExe, const Instance& inst, const std::string& apkPath);
bool processNonSelectedInstance(const std::string& adbExe, const Instance& inst, const std::string& scriptPath);
std::wstring stringToWstring(const std::string& str);
std::string runCommand(const std::string& cmd);

// Get the directory of the executable
std::string getExecutableDir() {
    wchar_t buffer[MAX_PATH];
    if (GetModuleFileNameW(nullptr, buffer, MAX_PATH) == 0) {
        std::cerr << "Failed to get executable path.\n";
        return "";
    }
    fs::path exePath(buffer);
    return exePath.parent_path().string();
}

// Convert std::string to std::wstring
std::wstring stringToWstring(const std::string& str) {
    if (str.empty()) return L"";
    int size_needed = MultiByteToWideChar(CP_UTF8, 0, &str[0], (int)str.size(), NULL, 0);
    std::wstring wstrTo(size_needed, 0);
    MultiByteToWideChar(CP_UTF8, 0, &str[0], (int)str.size(), &wstrTo[0], size_needed);
    return wstrTo;
}

// Retrieve a value from the Windows registry
std::string getRegistryValue(HKEY hkey, const std::string& subkey, const std::string& valueName) {
    HKEY key;
    std::wstring wSubkey = stringToWstring(subkey);
    std::wstring wValueName = stringToWstring(valueName);
    
    if (RegOpenKeyExW(hkey, wSubkey.c_str(), 0, KEY_READ, &key) != ERROR_SUCCESS) {
        return "";
    }

    WCHAR buffer[MAX_PATH];
    DWORD bufferSize = MAX_PATH * sizeof(WCHAR);
    DWORD type;

    if (RegQueryValueExW(key, wValueName.c_str(), nullptr, &type, (LPBYTE)buffer, &bufferSize) == ERROR_SUCCESS && type == REG_SZ) {
        RegCloseKey(key);
        std::wstring wBuffer(buffer);
        int size_needed = WideCharToMultiByte(CP_UTF8, 0, &wBuffer[0], (int)wBuffer.size(), NULL, 0, NULL, NULL);
        std::string strTo(size_needed, 0);
        WideCharToMultiByte(CP_UTF8, 0, &wBuffer[0], (int)wBuffer.size(), &strTo[0], size_needed, NULL, NULL);
        return strTo;
    }

    RegCloseKey(key);
    return "";
}

// Get the BlueStacks installation directory
std::string getBlueStacksInstallDir() {
    std::string installDir = getRegistryValue(HKEY_LOCAL_MACHINE, "SOFTWARE\\BlueStacks_nxt", "InstallDir");
    if (installDir.empty()) {
        std::cerr << "BlueStacks installation directory not found in registry. Falling back to default: C:\\Program Files\\BlueStacks_nxt\n";
        installDir = "C:\\Program Files\\BlueStacks_nxt";
    }
    return installDir;
}

// Get the BlueStacks data directory
std::string getBlueStacksDataDir() {
    std::string dataDir = getRegistryValue(HKEY_LOCAL_MACHINE, "SOFTWARE\\BlueStacks_nxt", "UserDefinedDir");
    if (dataDir.empty()) {
        std::cout << "BlueStacks data directory not found in registry. Using default: C:\\ProgramData\\BlueStacks_nxt\n";
        dataDir = "C:\\ProgramData\\BlueStacks_nxt";
    }
    return dataDir;
}

// Terminate BlueStacks processes
void terminateBlueStacksProcesses() {
    std::vector<std::string> processes = {
        "HD-MultiInstanceManager.exe",
        "HD-Player.exe",
        "BlueStacksHelper.exe",
        "BstkSVC.exe",
        "BlueStacksServices.exe"
    };
    for (const auto& proc : processes) {
        std::string cmd = "taskkill /IM \"" + proc + "\" /F 2>nul";
        std::system(cmd.c_str());
    }
    std::cout << "Terminated BlueStacks processes.\n";
}

// Enable ADB in configuration
void enableAdbInConfig(const std::string& confFile) {
    std::ifstream fileIn(confFile);
    if (!fileIn.is_open()) {
        std::cerr << "ERROR: Could not open " << confFile << " for reading.\n";
        return;
    }
    std::string content((std::istreambuf_iterator<char>(fileIn)), std::istreambuf_iterator<char>());
    fileIn.close();
    std::regex adbAccessRegex(R"(bst\.enable_adb_access=".*")");
    std::regex adbRemoteRegex(R"(bst\.enable_adb_remote_access=".*")");
    if (std::regex_search(content, adbAccessRegex)) {
        content = std::regex_replace(content, adbAccessRegex, R"(bst.enable_adb_access="1")");
    } else {
        content += "\nbst.enable_adb_access=\"1\"";
    }
    if (std::regex_search(content, adbRemoteRegex)) {
        content = std::regex_replace(content, adbRemoteRegex, R"(bst.enable_adb_remote_access="1")");
    } else {
        content += "\nbst.enable_adb_remote_access=\"1\"";
    }
    std::ofstream fileOut(confFile);
    if (!fileOut.is_open()) {
        std::cerr << "ERROR: Could not open " << confFile << " for writing.\n";
        return;
    }
    fileOut << content;
    fileOut.close();
    std::cout << "Updated " << confFile << " to enable ADB.\n";
}

// Ensure ADB is available
std::string ensureAdbAvailable(const std::string& bluestacksInstallDir) {
    std::string adbExe;
    std::string tempFile = getExecutableDir() + "\\adb_path.txt";
    if (std::system(("where adb > \"" + tempFile + "\" 2>&1").c_str()) == 0) {
        std::ifstream file(tempFile);
        if (file.is_open()) {
            std::getline(file, adbExe);
            file.close();
            if (!adbExe.empty() && fs::exists(adbExe)) {
                std::cout << "Using ADB from system PATH: " << adbExe << "\n";
                fs::remove(tempFile);
                return adbExe;
            }
        }
    }
    fs::remove(tempFile);
    std::string bluestacksAdb = bluestacksInstallDir + "\\adb.exe";
    if (fs::exists(bluestacksAdb)) {
        std::cout << "Using BlueStacks' ADB: " << bluestacksAdb << "\n";
        return bluestacksAdb;
    }
    std::string extractPath = getExecutableDir() + "\\platform-tools";
    std::string extractedAdb = extractPath + "\\adb.exe";
    if (!fs::exists(extractedAdb)) {
        std::string zipPath = getExecutableDir() + "\\platform-tools.zip";
        std::string downloadCmd = "powershell.exe -NoProfile -Command \"(New-Object Net.WebClient).DownloadFile('https://dl.google.com/android/repository/platform-tools-latest-windows.zip', '" + zipPath + "')\"";
        if (std::system(downloadCmd.c_str()) != 0 || !fs::exists(zipPath)) {
            std::cerr << "Failed to download platform-tools.zip.\n";
            return "";
        }
        std::string extractCmd = "powershell.exe -NoProfile -Command \"Expand-Archive -Path '" + zipPath + "' -DestinationPath '" + extractPath + "' -Force\"";
        if (std::system(extractCmd.c_str()) != 0 || !fs::exists(extractedAdb)) {
            std::cerr << "Failed to extract platform-tools.\n";
            fs::remove(zipPath);
            return "";
        }
        fs::remove(zipPath);
    }
    std::cout << "Using downloaded ADB: " << extractedAdb << "\n";
    return extractedAdb;
}

// Get or download the APK
std::string getApkPath() {
    std::string exeDir = getExecutableDir();
    std::string apkPath = exeDir + "\\magiskkitsune.apk";
    if (fs::exists(apkPath)) {
        std::cout << "Found magiskkitsune.apk at " << apkPath << "\n";
        return apkPath;
    }
    std::cout << "magiskkitsune.apk not found. Attempting to download...\n";
    std::string url = "https://raw.githubusercontent.com/Jordan231111/BluestacksRoot/refs/heads/main/magiskkitsune.apk";
    bool hasWget = (std::system("where wget >nul 2>&1") == 0);
    bool hasCurl = (std::system("where curl >nul 2>&1") == 0);
    if (hasWget) {
        std::string cmd = "wget -O \"" + apkPath + "\" " + url;
        if (std::system(cmd.c_str()) == 0 && fs::exists(apkPath)) {
            std::cout << "Downloaded APK using wget.\n";
            return apkPath;
        }
    } else if (hasCurl) {
        std::string cmd = "curl -L -o \"" + apkPath + "\" " + url;
        if (std::system(cmd.c_str()) == 0 && fs::exists(apkPath)) {
            std::cout << "Downloaded APK using curl.\n";
            return apkPath;
        }
    }
    std::cerr << "Failed to download magiskkitsune.apk. Place it in " << exeDir << " manually.\n";
    return "";
}

// Parse instances from bluestacks.conf
std::vector<Instance> parseInstances(const std::string& confFile) {
    std::map<std::string, Instance> instanceMap;
    std::regex pattern(R"(bst\.instance\.([^\.]+)\.([^\=]+)=(.*))");
    std::ifstream file(confFile);
    if (!file.is_open()) {
        std::cerr << "ERROR: Could not open " << confFile << "\n";
        return {};
    }
    std::string line;
    while (std::getline(file, line)) {
        std::smatch match;
        if (std::regex_search(line, match, pattern)) {
            std::string identifier = match[1].str();
            std::string key = match[2].str();
            std::string value = match[3].str();
            if (value.size() >= 2 && value[0] == '"' && value.back() == '"') {
                value = value.substr(1, value.size() - 2);
            }
            if (key == "display_name") {
                instanceMap[identifier].identifier = identifier;
                instanceMap[identifier].displayName = value;
            } else if (key == "adb_port") {
                instanceMap[identifier].adbPort = value;
            }
        }
    }
    file.close();
    std::vector<Instance> instances;
    for (const auto& pair : instanceMap) {
        if (!pair.second.displayName.empty()) {
            instances.push_back(pair.second);
        }
    }
    std::cout << "Found " << instances.size() << " instance(s):\n";
    return instances;
}

// Allow user to select multiple instances for rooting
std::vector<int> selectInstances(const std::vector<Instance>& instances) {
    if (instances.empty()) {
        return {};
    }
    for (size_t i = 0; i < instances.size(); ++i) {
        std::cout << i + 1 << ": " << instances[i].identifier << " - \"" << instances[i].displayName << "\"\n";
    }
    std::cout << "Enter instance numbers to process for rooting (comma-separated, e.g., 1,2,3): ";
    std::string input;
    std::getline(std::cin, input);
    std::istringstream iss(input);
    std::string token;
    std::vector<int> selected;
    while (std::getline(iss, token, ',')) {
        try {
            int num = std::stoi(token);
            if (num >= 1 && num <= static_cast<int>(instances.size())) {
                selected.push_back(num - 1);
            } else {
                std::cerr << "Invalid number: " << token << "\n";
            }
        } catch (const std::invalid_argument&) {
            std::cerr << "Invalid input: " << token << "\n";
        }
    }
    return selected;
}

// Helper function to run a command and capture its output
std::string runCommand(const std::string& cmd) {
    std::string result;
    // Use _popen on Windows
    FILE* pipe = _popen(cmd.c_str(), "r");
    if (!pipe) {
        return result;
    }
    constexpr size_t bufferSize = 128;
    char buffer[bufferSize];
    while (fgets(buffer, bufferSize, pipe) != nullptr) {
        result += buffer;
    }
    _pclose(pipe);
    return result;
}

// Connect to the instance with retry logic and output parsing
bool connectToInstance(const std::string& adbExe, const Instance& inst, std::string& device, int maxAttempts) {
    std::string port = inst.adbPort;
    if (port.empty()) {
        std::cerr << "No ADB port for instance " << inst.identifier << ".\n";
        return false;
    }
    device = "localhost:" + port;
    std::string connectCmd = adbExe + " connect " + device;
    std::string killServerCmd = adbExe + " kill-server";
    std::string startServerCmd = adbExe + " start-server";

    std::cout << "Killing any existing ADB server...\n";
    std::system(killServerCmd.c_str());

    for (int attempt = 0; attempt < maxAttempts; ++attempt) {
        std::cout << "Attempt " << attempt + 1 << " of " << maxAttempts << " to connect to " << inst.identifier << "...\n";
        std::system(startServerCmd.c_str());
        std::string output = runCommand(connectCmd);

        // Check if the output indicates a connection
        if (output.find("connected to") != std::string::npos) {
            // Further verify the connection state
            std::string stateCmd = adbExe + " -s " + device + " get-state";
            std::string stateOutput = runCommand(stateCmd);
            if (stateOutput.find("device") != std::string::npos) {
                std::cout << "Successfully connected to " << inst.identifier << ".\n";
                return true;
            }
        }
        std::cerr << "Connection attempt " << attempt + 1 << " did not fully succeed. Killing ADB server...\n";
        std::system(killServerCmd.c_str());
        std::this_thread::sleep_for(std::chrono::seconds(18));
    }
    std::cerr << "Failed to connect to " << inst.identifier << " after " << maxAttempts << " attempts.\n";
    return false;
}

// Install APK on a specific instance
bool installApkOnInstance(const std::string& adbExe, const Instance& inst, const std::string& apkPath) {
    std::string device;
    if (!connectToInstance(adbExe, inst, device)) {
        return false;
    }
    std::string waitCmd = adbExe + " -s " + device + " wait-for-device";
    std::system(waitCmd.c_str());
    std::string installCmd = adbExe + " -s " + device + " install -r \"" + apkPath + "\"";
    std::cout << "Installing APK on " << inst.identifier << "...\n";
    if (std::system(installCmd.c_str()) == 0) {
        std::cout << "Successfully installed APK on " << inst.identifier << ".\n";
        return true;
    } else {
        std::cerr << "APK installation failed on " << inst.identifier << ".\n";
        return false;
    }
}

bool processNonSelectedInstance(const std::string& adbExe, const Instance& inst, const std::string& scriptPath) {
    std::string device;
    if (!connectToInstance(adbExe, inst, device)) {
        return false;
    }

    // Retry logic for pushing the script
    const int maxRetries = 3;
    int attempt = 0;
    bool pushSuccess = false;
    while (attempt < maxRetries && !pushSuccess) {
        std::string pushCmd = adbExe + " -s " + device + " push \"" + scriptPath + "\" /sdcard/uninstall_script.sh";
        if (std::system(pushCmd.c_str()) == 0) {
            std::cout << "Pushed script to " << inst.identifier << "\n";
            pushSuccess = true;
        } else {
            std::cerr << "Attempt " << (attempt + 1) << " failed to push script to " << inst.identifier << "\n";
            attempt++;
            if (attempt < maxRetries) {
                std::this_thread::sleep_for(std::chrono::seconds(2));  // Wait before retrying
            }
        }
    }

    if (!pushSuccess) {
        std::cerr << "Failed to push script to " << inst.identifier << " after " << maxRetries << " attempts.\n";
        return false;
    }

    // Execute the script on the device
    std::string execCmd = adbExe + " -s " + device + " shell \"sh /sdcard/uninstall_script.sh\"";
    if (std::system(execCmd.c_str()) == 0) {
        std::cout << "Executed script on " << inst.identifier << "\n";
    } else {
        std::cerr << "Failed to execute script on " << inst.identifier << " (might be expected if package not installed).\n";
    }
    return true;
}

int main() {
    // Get BlueStacks installation and data directories
    std::string bluestacksInstallDir = getBlueStacksInstallDir();
    if (bluestacksInstallDir.empty()) {
        std::cerr << "Could not determine BlueStacks installation directory.\n";
        return 1;
    }
    std::string bluestacksDataDir = getBlueStacksDataDir();
    std::string confFile = bluestacksDataDir + "\\bluestacks.conf";
    std::cout << "Using configuration file: " << confFile << "\n";

    // Terminate BlueStacks processes to ensure a clean state
    terminateBlueStacksProcesses();

    // Enable ADB in configuration
    enableAdbInConfig(confFile);

    // Parse instances
    std::vector<Instance> instances = parseInstances(confFile);
    if (instances.empty()) {
        std::cerr << "No instances found in configuration file.\n";
        return 1;
    }

    // Select instances for rooting
    std::vector<int> selectedIndices = selectInstances(instances);
    if (selectedIndices.empty()) {
        std::cerr << "No instances selected for rooting.\n";
        return 1;
    }

    // Create selected and non-selected instance lists
    std::vector<Instance> selectedInstances;
    for (int index : selectedIndices) {
        selectedInstances.push_back(instances[index]);
    }
    std::vector<Instance> nonSelectedInstances;
    for (size_t i = 0; i < instances.size(); ++i) {
        if (std::find(selectedIndices.begin(), selectedIndices.end(), static_cast<int>(i)) == selectedIndices.end()) {
            nonSelectedInstances.push_back(instances[i]);
        }
    }

    // Start selected instances using CreateProcessW to track PIDs
    std::string bluestacksExe = bluestacksInstallDir + "\\HD-Player.exe";
    if (!fs::exists(bluestacksExe)) {
        std::cerr << "BlueStacks executable not found at " << bluestacksExe << ".\n";
        return 1;
    }
    std::map<std::string, HANDLE> instanceProcesses;
    for (const auto& inst : selectedInstances) {
        std::wstring wBluestacksExe = stringToWstring(bluestacksExe);
        std::wstring wIdentifier = stringToWstring(inst.identifier);
        std::wstring startCmd = L"\"" + wBluestacksExe + L"\" --instance " + wIdentifier;
        STARTUPINFOW si = { sizeof(si) };
        PROCESS_INFORMATION pi;
        if (CreateProcessW(NULL, &startCmd[0], NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
            instanceProcesses[inst.identifier] = pi.hProcess;
            std::cout << "Started selected instance " << inst.identifier << " with PID " << pi.dwProcessId << "\n";
            CloseHandle(pi.hThread);
        } else {
            std::cerr << "Failed to start instance " << inst.identifier << "\n";
        }
    }
    std::cout << "Waiting for selected instances to start (10 seconds)...\n";
    std::this_thread::sleep_for(std::chrono::seconds(10));

    // Ensure ADB is available
    std::string adbExe = ensureAdbAvailable(bluestacksInstallDir);
    if (adbExe.empty()) {
        std::cerr << "ADB is not available.\n";
        return 1;
    }

    // Get or download the APK
    std::string apkPath = getApkPath();
    if (apkPath.empty()) {
        std::cerr << "magiskkitsune.apk is not available.\n";
        return 1;
    }

    // Process each selected instance for APK installation
    for (const auto& inst : selectedInstances) {
        std::cout << "Processing selected instance: " << inst.identifier << " (Port: " << inst.adbPort << ")\n";
        if (installApkOnInstance(adbExe, inst, apkPath)) {
            std::cout << "Successfully installed APK on " << inst.identifier << ".\n";
        } else {
            std::cerr << "Failed to install APK on " << inst.identifier << ". Continuing with other instances.\n";
        }
    }

    // Kill selected (rooted) instances
    for (const auto& pair : instanceProcesses) {
        TerminateProcess(pair.second, 0);
        CloseHandle(pair.second);
        std::cout << "Killed instance " << pair.first << "\n";
    }
    instanceProcesses.clear();

    // Create the uninstall script
    std::string scriptContent = R"(#!/system/bin/sh
if [ -d "/data/adb" ]; then
    su -c 'rm -rf /data/adb'
fi
if [ -d "/sbin" ]; then
    su -c 'rm -rf /sbin'
fi
su -c 'pm uninstall --user 0 io.github.huskydg.magisk'
)";
    std::string scriptPath = getExecutableDir() + "\\uninstall_script.sh";
    std::ofstream scriptFile(scriptPath);
    if (scriptFile.is_open()) {
        scriptFile << scriptContent;
        scriptFile.close();
        std::cout << "Created uninstall script at " << scriptPath << "\n";
    } else {
        std::cerr << "Failed to create uninstall script.\n";
        return 1;
    }

    // Launch non-selected instances
    for (const auto& inst : nonSelectedInstances) {
        std::string startCmd = "start \"\" \"" + bluestacksExe + "\" --instance " + inst.identifier;
        std::cout << "Starting non-selected instance " << inst.identifier << "...\n";
        std::system(startCmd.c_str());
    }
    std::cout << "Waiting for non-selected instances to start (10 seconds)...\n";
    std::this_thread::sleep_for(std::chrono::seconds(10));

    // Process each non-selected instance with the script
    for (const auto& inst : nonSelectedInstances) {
        std::cout << "Processing non-selected instance: " << inst.identifier << " (Port: " << inst.adbPort << ")\n";
        if (processNonSelectedInstance(adbExe, inst, scriptPath)) {
            std::cout << "Processed " << inst.identifier << ". Check logs for details.\n";
        } else {
            std::cerr << "Failed to connect to " << inst.identifier << " for processing.\n";
        }
    }

    std::cout << "All selected and non-selected instances processed.\n";
    return 0;
}
