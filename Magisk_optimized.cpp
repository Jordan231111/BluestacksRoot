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
#include <memory>
#include <future>
#include <mutex>

namespace fs = std::filesystem;

// Performance Optimization: Use string_view for read-only operations
using string_view = std::string_view;

// Structure to hold instance details with move semantics
struct Instance {
    std::string identifier;
    std::string displayName;
    std::string adbPort;
    
    // Performance Optimization: Move constructor
    Instance(Instance&& other) noexcept 
        : identifier(std::move(other.identifier))
        , displayName(std::move(other.displayName))
        , adbPort(std::move(other.adbPort)) {}
    
    Instance& operator=(Instance&& other) noexcept {
        if (this != &other) {
            identifier = std::move(other.identifier);
            displayName = std::move(other.displayName);
            adbPort = std::move(other.adbPort);
        }
        return *this;
    }
    
    Instance() = default;
    Instance(const Instance&) = default;
    Instance& operator=(const Instance&) = default;
};

// Performance Optimization: Cache class for registry values
class RegistryCache {
private:
    std::map<std::string, std::string> cache;
    std::mutex cacheMutex;
    std::chrono::steady_clock::time_point lastUpdate;
    static constexpr auto CACHE_DURATION = std::chrono::minutes(5);

public:
    std::string getValue(const std::string& key, const std::string& subkey, const std::string& valueName) {
        std::lock_guard<std::mutex> lock(cacheMutex);
        
        auto cacheKey = key + "\\" + subkey + "\\" + valueName;
        auto now = std::chrono::steady_clock::now();
        
        // Check if cache is still valid
        if (now - lastUpdate < CACHE_DURATION && cache.find(cacheKey) != cache.end()) {
            return cache[cacheKey];
        }
        
        // Fetch from registry
        std::string value = getRegistryValue(key, subkey, valueName);
        cache[cacheKey] = value;
        lastUpdate = now;
        
        return value;
    }
    
private:
    std::string getRegistryValue(const std::string& key, const std::string& subkey, const std::string& valueName) {
        // Implementation of registry reading (moved from global function)
        HKEY hkey = (key == "HKEY_LOCAL_MACHINE") ? HKEY_LOCAL_MACHINE : HKEY_CURRENT_USER;
        HKEY regKey;
        
        std::wstring wSubkey = stringToWstring(subkey);
        std::wstring wValueName = stringToWstring(valueName);
        
        if (RegOpenKeyExW(hkey, wSubkey.c_str(), 0, KEY_READ, &regKey) != ERROR_SUCCESS) {
            return "";
        }
        
        WCHAR buffer[MAX_PATH];
        DWORD bufferSize = MAX_PATH * sizeof(WCHAR);
        DWORD type;
        
        if (RegQueryValueExW(regKey, wValueName.c_str(), nullptr, &type, (LPBYTE)buffer, &bufferSize) == ERROR_SUCCESS && type == REG_SZ) {
            RegCloseKey(regKey);
            return wstringToString(std::wstring(buffer));
        }
        
        RegCloseKey(regKey);
        return "";
    }
    
    std::wstring stringToWstring(const std::string& str) {
        if (str.empty()) return L"";
        int size_needed = MultiByteToWideChar(CP_UTF8, 0, &str[0], (int)str.size(), NULL, 0);
        std::wstring wstrTo(size_needed, 0);
        MultiByteToWideChar(CP_UTF8, 0, &str[0], (int)str.size(), &wstrTo[0], size_needed);
        return wstrTo;
    }
    
    std::string wstringToString(const std::wstring& wstr) {
        if (wstr.empty()) return "";
        int size_needed = WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(), NULL, 0, NULL, NULL);
        std::string strTo(size_needed, 0);
        WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(), &strTo[0], size_needed, NULL, NULL);
        return strTo;
    }
};

// Performance Optimization: Smart pointer for resource management
class BlueStacksManager {
private:
    std::unique_ptr<RegistryCache> regCache;
    std::string installDir;
    std::string dataDir;
    std::string confFile;
    
public:
    BlueStacksManager() : regCache(std::make_unique<RegistryCache>()) {
        initialize();
    }
    
    void initialize() {
        // Performance Optimization: Use cached registry access
        installDir = regCache->getValue("HKEY_LOCAL_MACHINE", "SOFTWARE\\BlueStacks_nxt", "InstallDir");
        if (installDir.empty()) {
            std::cerr << "BlueStacks installation directory not found in registry. Using default.\n";
            installDir = "C:\\Program Files\\BlueStacks_nxt";
        }
        
        dataDir = regCache->getValue("HKEY_LOCAL_MACHINE", "SOFTWARE\\BlueStacks_nxt", "UserDefinedDir");
        if (dataDir.empty()) {
            std::cout << "BlueStacks data directory not found in registry. Using default.\n";
            dataDir = "C:\\ProgramData\\BlueStacks_nxt";
        }
        
        confFile = dataDir + "\\bluestacks.conf";
    }
    
    const std::string& getInstallDir() const { return installDir; }
    const std::string& getDataDir() const { return dataDir; }
    const std::string& getConfFile() const { return confFile; }
};

// Performance Optimization: Process manager for parallel operations
class ProcessManager {
private:
    std::vector<std::string> bluestacksProcesses = {
        "HD-MultiInstanceManager.exe",
        "HD-Player.exe", 
        "BlueStacksHelper.exe",
        "BstkSVC.exe",
        "BlueStacksServices.exe"
    };
    
public:
    void terminateBlueStacksProcesses() {
        std::vector<std::future<void>> futures;
        
        // Performance Optimization: Parallel process termination
        for (const auto& proc : bluestacksProcesses) {
            futures.push_back(std::async(std::launch::async, [proc]() {
                std::string cmd = "taskkill /IM \"" + proc + "\" /F 2>nul";
                std::system(cmd.c_str());
            }));
        }
        
        // Wait for all terminations to complete
        for (auto& future : futures) {
            future.wait();
        }
        
        std::cout << "Terminated BlueStacks processes (parallel).\n";
    }
};

// Performance Optimization: File operations with streaming
class FileManager {
public:
    // Performance Optimization: Stream-based file modification
    static bool modifyConfigFile(const std::string& confFile, bool enableRoot) {
        std::ifstream input(confFile);
        if (!input.is_open()) {
            std::cerr << "ERROR: Could not open " << confFile << " for reading.\n";
            return false;
        }
        
        std::stringstream buffer;
        std::string line;
        bool adbAccessFound = false;
        bool adbRemoteFound = false;
        
        // Performance Optimization: Process file line by line instead of loading entire file
        while (std::getline(input, line)) {
            if (line.find("bst.enable_adb_access=") != std::string::npos) {
                line = "bst.enable_adb_access=\"1\"";
                adbAccessFound = true;
            } else if (line.find("bst.enable_adb_remote_access=") != std::string::npos) {
                line = "bst.enable_adb_remote_access=\"1\"";
                adbRemoteFound = true;
            } else if (enableRoot) {
                if (line.find("enable_root_access=") != std::string::npos) {
                    line = std::regex_replace(line, std::regex("enable_root_access=\"0\""), "enable_root_access=\"1\"");
                } else if (line.find("bst.feature.rooting=") != std::string::npos) {
                    line = std::regex_replace(line, std::regex("bst.feature.rooting=\"0\""), "bst.feature.rooting=\"1\"");
                }
            }
            buffer << line << "\n";
        }
        input.close();
        
        // Add missing entries
        if (!adbAccessFound) {
            buffer << "bst.enable_adb_access=\"1\"\n";
        }
        if (!adbRemoteFound) {
            buffer << "bst.enable_adb_remote_access=\"1\"\n";
        }
        
        // Write back to file
        std::ofstream output(confFile);
        if (!output.is_open()) {
            std::cerr << "ERROR: Could not open " << confFile << " for writing.\n";
            return false;
        }
        
        output << buffer.str();
        output.close();
        
        std::cout << "Updated " << confFile << " with streaming I/O.\n";
        return true;
    }
    
    // Performance Optimization: Efficient file size check
    static bool isFileSizeReasonable(const std::string& filePath, size_t maxSizeMB = 10) {
        try {
            auto fileSize = fs::file_size(filePath);
            return fileSize <= (maxSizeMB * 1024 * 1024);
        } catch (const fs::filesystem_error&) {
            return false;
        }
    }
};

// Performance Optimization: Optimized instance parser
class InstanceParser {
public:
    static std::vector<Instance> parseInstances(const std::string& confFile) {
        std::map<std::string, Instance> instanceMap;
        std::regex pattern(R"(bst\.instance\.([^\.]+)\.([^\=]+)=(.*))");
        
        std::ifstream file(confFile);
        if (!file.is_open()) {
            std::cerr << "ERROR: Could not open " << confFile << "\n";
            return {};
        }
        
        std::string line;
        // Performance Optimization: Reserve memory for better performance
        line.reserve(256);
        
        while (std::getline(file, line)) {
            std::smatch match;
            if (std::regex_search(line, match, pattern)) {
                std::string identifier = match[1].str();
                std::string key = match[2].str();
                std::string value = match[3].str();
                
                // Performance Optimization: Remove quotes more efficiently
                if (value.length() >= 2 && value.front() == '"' && value.back() == '"') {
                    value = value.substr(1, value.length() - 2);
                }
                
                auto& instance = instanceMap[identifier];
                instance.identifier = identifier;
                
                if (key == "display_name") {
                    instance.displayName = std::move(value);
                } else if (key == "adb_port") {
                    instance.adbPort = std::move(value);
                }
            }
        }
        
        // Performance Optimization: Use move semantics
        std::vector<Instance> instances;
        instances.reserve(instanceMap.size());
        
        for (auto& [id, instance] : instanceMap) {
            if (!instance.displayName.empty()) {
                instances.push_back(std::move(instance));
            }
        }
        
        std::cout << "Found " << instances.size() << " instance(s) with optimized parsing.\n";
        return instances;
    }
};

// Performance Optimization: Concurrent ADB manager
class ADBManager {
private:
    std::string adbExecutable;
    std::mutex adbMutex;
    
public:
    ADBManager(const std::string& bluestacksInstallDir) {
        adbExecutable = ensureAdbAvailable(bluestacksInstallDir);
    }
    
    // Performance Optimization: Concurrent instance processing
    bool processInstancesConcurrently(const std::vector<Instance>& instances, 
                                    const std::string& apkPath,
                                    const std::vector<int>& selectedIndices) {
        std::vector<std::future<bool>> futures;
        
        // Process selected instances in parallel
        for (int index : selectedIndices) {
            if (index < 0 || index >= instances.size()) continue;
            
            const auto& instance = instances[index];
            futures.push_back(std::async(std::launch::async, [this, &instance, &apkPath]() {
                return this->installApkOnInstance(instance, apkPath);
            }));
        }
        
        // Wait for all installations to complete
        bool allSuccessful = true;
        for (auto& future : futures) {
            if (!future.get()) {
                allSuccessful = false;
            }
        }
        
        return allSuccessful;
    }
    
private:
    std::string ensureAdbAvailable(const std::string& bluestacksInstallDir) {
        // Performance Optimization: Check system PATH first (faster)
        std::string tempFile = fs::temp_directory_path().string() + "\\adb_check.tmp";
        
        if (std::system(("where adb > \"" + tempFile + "\" 2>&1").c_str()) == 0) {
            std::ifstream file(tempFile);
            std::string adbPath;
            if (file.is_open() && std::getline(file, adbPath)) {
                file.close();
                fs::remove(tempFile);
                if (fs::exists(adbPath)) {
                    std::cout << "Using system ADB: " << adbPath << "\n";
                    return adbPath;
                }
            }
        }
        
        // Check BlueStacks directory
        std::string bluestacksAdb = bluestacksInstallDir + "\\adb.exe";
        if (fs::exists(bluestacksAdb)) {
            std::cout << "Using BlueStacks ADB: " << bluestacksAdb << "\n";
            return bluestacksAdb;
        }
        
        // Download if necessary (optimized)
        return downloadAdb();
    }
    
    std::string downloadAdb() {
        std::string extractPath = fs::temp_directory_path().string() + "\\platform-tools";
        std::string extractedAdb = extractPath + "\\adb.exe";
        
        if (fs::exists(extractedAdb)) {
            std::cout << "Using cached ADB: " << extractedAdb << "\n";
            return extractedAdb;
        }
        
        std::cout << "Downloading ADB platform tools...\n";
        std::string zipPath = fs::temp_directory_path().string() + "\\platform-tools.zip";
        
        // Performance Optimization: Use PowerShell for faster download
        std::string downloadCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"& {[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile('https://dl.google.com/android/repository/platform-tools-latest-windows.zip', '" + zipPath + "')}\"";
        
        if (std::system(downloadCmd.c_str()) != 0 || !fs::exists(zipPath)) {
            std::cerr << "Failed to download platform-tools.zip.\n";
            return "";
        }
        
        std::string extractCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"Expand-Archive -Path '" + zipPath + "' -DestinationPath '" + extractPath + "' -Force\"";
        
        if (std::system(extractCmd.c_str()) != 0 || !fs::exists(extractedAdb)) {
            std::cerr << "Failed to extract platform-tools.\n";
            fs::remove(zipPath);
            return "";
        }
        
        fs::remove(zipPath);
        std::cout << "ADB downloaded and extracted successfully.\n";
        return extractedAdb;
    }
    
    bool installApkOnInstance(const Instance& instance, const std::string& apkPath) {
        std::string device = "localhost:" + instance.adbPort;
        
        // Performance Optimization: Optimized connection with retry logic
        if (!connectToInstanceOptimized(device, instance.identifier)) {
            return false;
        }
        
        std::string installCmd = adbExecutable + " -s " + device + " install -r \"" + apkPath + "\"";
        std::cout << "Installing APK on " << instance.identifier << "...\n";
        
        if (std::system(installCmd.c_str()) == 0) {
            std::cout << "Successfully installed APK on " << instance.identifier << ".\n";
            return true;
        } else {
            std::cerr << "APK installation failed on " << instance.identifier << ".\n";
            return false;
        }
    }
    
    bool connectToInstanceOptimized(const std::string& device, const std::string& instanceId) {
        const int maxAttempts = 3;
        const int retryDelay = 2; // seconds
        
        for (int attempt = 0; attempt < maxAttempts; ++attempt) {
            std::cout << "Connecting to " << instanceId << " (attempt " << (attempt + 1) << "/" << maxAttempts << ")\n";
            
            // Performance Optimization: Quick connection test
            std::string connectCmd = adbExecutable + " connect " + device + " 2>nul";
            if (std::system(connectCmd.c_str()) == 0) {
                
                // Verify connection
                std::string testCmd = adbExecutable + " -s " + device + " shell echo connected 2>nul";
                if (std::system(testCmd.c_str()) == 0) {
                    std::cout << "Successfully connected to " << instanceId << "\n";
                    return true;
                }
            }
            
            if (attempt < maxAttempts - 1) {
                std::this_thread::sleep_for(std::chrono::seconds(retryDelay));
            }
        }
        
        std::cerr << "Failed to connect to " << instanceId << " after " << maxAttempts << " attempts.\n";
        return false;
    }
};

// Performance Optimization: Main application class
class BlueStacksRootTool {
private:
    std::unique_ptr<BlueStacksManager> bsManager;
    std::unique_ptr<ProcessManager> processManager;
    std::unique_ptr<ADBManager> adbManager;
    
public:
    BlueStacksRootTool() {
        bsManager = std::make_unique<BlueStacksManager>();
        processManager = std::make_unique<ProcessManager>();
        adbManager = std::make_unique<ADBManager>(bsManager->getInstallDir());
    }
    
    int run() {
        std::cout << "BlueStacks Root Tool - Optimized Version\n";
        std::cout << "========================================\n";
        
        // Performance Optimization: Early validation
        if (!validateEnvironment()) {
            return 1;
        }
        
        // Terminate processes
        processManager->terminateBlueStacksProcesses();
        
        // Enable ADB in configuration
        if (!FileManager::modifyConfigFile(bsManager->getConfFile(), false)) {
            std::cerr << "Failed to enable ADB in configuration.\n";
            return 1;
        }
        
        // Parse instances
        auto instances = InstanceParser::parseInstances(bsManager->getConfFile());
        if (instances.empty()) {
            std::cerr << "No instances found in configuration file.\n";
            return 1;
        }
        
        // Select instances
        auto selectedIndices = selectInstances(instances);
        if (selectedIndices.empty()) {
            std::cerr << "No instances selected for rooting.\n";
            return 1;
        }
        
        // Get APK path
        std::string apkPath = getApkPath();
        if (apkPath.empty()) {
            std::cerr << "APK file not available.\n";
            return 1;
        }
        
        // Performance Optimization: Process instances concurrently
        if (!adbManager->processInstancesConcurrently(instances, apkPath, selectedIndices)) {
            std::cerr << "Some installations failed.\n";
            return 1;
        }
        
        std::cout << "All operations completed successfully!\n";
        return 0;
    }
    
private:
    bool validateEnvironment() {
        // Performance Optimization: Quick environment validation
        if (!fs::exists(bsManager->getConfFile())) {
            std::cerr << "BlueStacks configuration file not found: " << bsManager->getConfFile() << "\n";
            return false;
        }
        
        if (!fs::exists(bsManager->getInstallDir())) {
            std::cerr << "BlueStacks installation directory not found: " << bsManager->getInstallDir() << "\n";
            return false;
        }
        
        return true;
    }
    
    std::vector<int> selectInstances(const std::vector<Instance>& instances) {
        std::cout << "Available instances:\n";
        for (size_t i = 0; i < instances.size(); ++i) {
            std::cout << (i + 1) << ": " << instances[i].identifier 
                      << " - \"" << instances[i].displayName << "\"\n";
        }
        
        std::cout << "Enter instance numbers (comma-separated): ";
        std::string input;
        std::getline(std::cin, input);
        
        std::vector<int> selected;
        std::stringstream ss(input);
        std::string token;
        
        while (std::getline(ss, token, ',')) {
            try {
                int num = std::stoi(token);
                if (num >= 1 && num <= static_cast<int>(instances.size())) {
                    selected.push_back(num - 1);
                }
            } catch (const std::exception&) {
                std::cerr << "Invalid input: " << token << "\n";
            }
        }
        
        return selected;
    }
    
    std::string getApkPath() {
        std::string apkPath = fs::current_path().string() + "\\magiskkitsune.apk";
        
        if (fs::exists(apkPath)) {
            std::cout << "Found APK: " << apkPath << "\n";
            return apkPath;
        }
        
        std::cout << "APK not found locally. Please ensure magiskkitsune.apk is in the current directory.\n";
        return "";
    }
};

// Performance Optimization: Main function with error handling
int main() {
    try {
        auto startTime = std::chrono::high_resolution_clock::now();
        
        BlueStacksRootTool tool;
        int result = tool.run();
        
        auto endTime = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(endTime - startTime);
        
        std::cout << "\nExecution completed in " << duration.count() << "ms\n";
        
        return result;
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << "\n";
        return 1;
    }
}