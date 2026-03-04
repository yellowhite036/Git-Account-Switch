#!/bin/bash

# Git Account Switcher for Linux (V2)
# 處理 Git 設定, SSH Config 別名, 以及設定檔持久化。

# --- 全域配置 ---
PROFILES_PATH="$HOME/.github-profiles.json"
SSH_CONFIG_PATH="$HOME/.ssh/config"

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# --- 檢查依賴 ---
if ! command -v jq &> /dev/null; then
    echo -e "${RED}錯誤: 系統未安裝 'jq'。請先安裝以使用此腳本。${NC}"
    echo -e "${YELLOW}提示: sudo apt install jq (或對應系統的套件管理器)${NC}"
    exit 1
fi

# 路徑展開函數 (處理 ~)
expand_path() {
    echo "${1/#\~/$HOME}"
}

# --- 讀取/儲存設定檔 ---
get_profiles() {
    if [[ -f "$PROFILES_PATH" ]]; then
        cat "$PROFILES_PATH"
    else
        # 預設範例
        local defaults='{
            "personal": { "name": "personal", "email": "personal@gmail.com", "ssh": "~/.ssh/id_rsa_personal" },
            "work":     { "name": "work", "email": "work@gmail.com", "ssh": "~/.ssh/id_rsa_work" }
        }'
        echo "$defaults" > "$PROFILES_PATH"
        echo "$defaults"
    fi
}

save_profiles() {
    echo "$1" | jq '.' > "$PROFILES_PATH"
}

# --- SSH Config 管理 ---
update_ssh_config() {
    local profile_name=$1
    local ssh_path=$2
    local full_key_path=$(expand_path "$ssh_path")
    local host_alias="github.com-$profile_name"
    
    mkdir -p "$(dirname "$SSH_CONFIG_PATH")"
    touch "$SSH_CONFIG_PATH"

    local entry="\nHost $host_alias\n    HostName github.com\n    User git\n    IdentityFile \"$full_key_path\"\n    IdentitiesOnly yes"

    if grep -q "Host $host_alias" "$SSH_CONFIG_PATH"; then
        if ! grep -q "IdentityFile \"$full_key_path\"" "$SSH_CONFIG_PATH"; then
             echo -e "${YELLOW}注意: $host_alias 的 SSH 設定已存在，但金鑰路徑可能不同。${NC}"
        fi
    else
        echo -e "${CYAN}添加新的 SSH Config 別名: $host_alias${NC}"
        echo -e "$entry" >> "$SSH_CONFIG_PATH"
    fi
}

# --- 身份驗證測試 ---
test_github_identity() {
    local host_alias=$1
    echo -e "\n${CYAN}正在驗證 $host_alias 的身份...${NC}"
    # 使用 SSH 測試連線
    local result=$(ssh -T -o "ConnectTimeout=5" -o "StrictHostKeyChecking=no" "$host_alias" 2>&1)
    if [[ $result =~ Hi\ ([^!]+)! ]]; then
        echo -e "${GREEN}驗證成功！目前身份為: [${BASH_REMATCH[1]}]${NC}"
    else
        echo -e "${YELLOW}驗證失敗。結果：${NC}"
        echo -e "${GRAY}$result${NC}"
    fi
}

# --- 生成新金鑰 ---
new_ssh_key() {
    local path=$1
    local email=$2
    local full_path=$(expand_path "$path")
    
    echo -e "${YELLOW}找不到金鑰：$full_path${NC}"
    read -p "是否生成新的 Ed25519 金鑰？ (a=100 rounds) (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        mkdir -p "$(dirname "$full_path")"
        ssh-keygen -t ed25519 -a 100 -C "$email" -f "$full_path" -N ""
        local pub_key=$(cat "${full_path}.pub")
        echo -e "\n${GREEN}金鑰生成成功！${NC}"
        
        # 嘗試複製到剪貼簿 (Linux 常見工具)
        if command -v xclip &> /dev/null; then
            echo -n "$pub_key" | xclip -selection clipboard
            echo -e "${GREEN}公鑰已複製到剪貼簿 (xclip)。${NC}"
        elif command -v wl-copy &> /dev/null; then
            echo -n "$pub_key" | wl-copy
            echo -e "${GREEN}公鑰已複製到剪貼簿 (wl-copy)。${NC}"
        else
            echo -e "${YELLOW}未偵測到剪貼簿工具，請手動複製公鑰：${NC}"
            echo "$pub_key"
        fi
        return 0
    fi
    return 1
}

# --- 更新倉庫 Remote URLs ---
update_repo_remotes() {
    local repo_dir=$1
    local profile_name=$2
    local updated=0
    
    cd "$repo_dir" || return 0
    local remotes=$(git remote)
    
    for remote in $remotes; do
        local url=$(git remote get-url "$remote")
        # 匹配 HTTPS 或標準 SSH 格式
        if [[ $url =~ https://github\.com/(.+) ]] || [[ $url =~ git@github\.com:(.+) ]]; then
            local repo_path=${BASH_REMATCH[1]}
            local new_url="git@github.com-$profile_name:$repo_path"
            git remote set-url "$remote" "$new_url"
            echo -e "  ${GREEN}[已更新] $remote${NC}"
            echo -e "    Before: $url"
            echo -e "    After:  $new_url"
            ((updated++))
        fi
    done
}

# --- 主要切換邏輯 ---
switch_git_account() {
    local profile_name=$1
    local profiles=$2
    
    local name=$(echo "$profiles" | jq -r ".[\"$profile_name\"].name")
    local email=$(echo "$profiles" | jq -r ".[\"$profile_name\"].email")
    local ssh_path=$(echo "$profiles" | jq -r ".[\"$profile_name\"].ssh")
    
    echo -e "\n${MAGENTA}正在切換至 [$profile_name] ($email)${NC}"
    echo "套用範圍: (1) Global (全域系統)  (2) Local (僅目前倉庫)"
    read -p "請選擇: " scope_choice
    
    local scope="--global"
    if [[ "$scope_choice" == "2" ]]; then
        scope="--local"
        if ! git rev-parse --is-inside-work-tree &> /dev/null; then
            echo -e "${RED}錯誤: 目前目錄不在 Git 倉庫中。無法套用 Local 設定。${NC}"
            return
        fi
    fi

    # 1. Git Config
    git config "$scope" user.name "$name"
    git config "$scope" user.email "$email"

    # 2. SSH Agent
    if [[ -n "$SSH_AUTH_SOCK" ]]; then
        ssh-add -D &> /dev/null # 清除舊金鑰
        local full_ssh_path=$(expand_path "$ssh_path")
        if [[ ! -f "$full_ssh_path" ]]; then
            new_ssh_key "$ssh_path" "$email"
        fi
        if [[ -f "$full_ssh_path" ]]; then
            ssh-add "$full_ssh_path" &> /dev/null
        fi
    fi

    # 3. SSH Config Alias
    update_ssh_config "$profile_name" "$ssh_path"

    # 4. 更新 Remote URLs
    echo -e "\n${CYAN}[更新 Remote URL]${NC}"
    echo "請輸入要更新 Remote 到別名的倉庫路徑 (可輸入多個，以空白隔開)。"
    echo "  - 直接將資料夾拖曳進來即可"
    echo "  - 直接按 Enter 則跳過"
    read -p "路徑: " repo_paths

    if [[ -n "$repo_paths" ]]; then
        # 處理多路徑 (處理引號)
        eval "paths=($repo_paths)"
        for repo_dir in "${paths[@]}"; do
            repo_dir=$(expand_path "$repo_dir")
            if [[ -d "$repo_dir" ]]; then
                if (cd "$repo_dir" && git rev-parse --is-inside-work-tree &> /dev/null); then
                    echo -e "\n${YELLOW}倉庫路徑: $repo_dir${NC}"
                    update_repo_remotes "$repo_dir" "$profile_name"
                else
                    echo -e "  ${RED}不是有效的 Git 倉庫: $repo_dir${NC}"
                fi
            else
                echo -e "  ${RED}找不到路徑: $repo_dir${NC}"
            fi
        done
    else
        echo -e "  已跳過 Remote 更新。"
    fi

    # 5. 顯示結果
    echo -e "\n${GREEN}設定已套用 ($scope):${NC}"
    echo "  姓名: $name"
    echo "  郵件: $email"
    echo -e "  SSH Alias: ${GRAY}github.com-$profile_name${NC}"
    
    test_github_identity "github.com-$profile_name"
    
    echo -e "\n${CYAN}[小提示] 之後 Clone 倉庫時請使用別名：${NC}"
    echo -e "git clone git@github.com-$profile_name:使用者名稱/專案.git"
}

# --- 狀態檢查 ---
show_current_status() {
    echo -e "\n${CYAN}=== 目前 Git & SSH 狀態 ===${NC}"
    
    echo -e "${YELLOW}[Local 設定] (目前倉庫)${NC}"
    if git rev-parse --is-inside-work-tree &> /dev/null; then
        echo "  姓名: $(git config --local user.name)"
        echo "  郵件: $(git config --local user.email)"
    else
        echo -e "  ${GRAY}(不在 Git 倉庫中)${NC}"
    fi

    echo -e "\n${YELLOW}[Global 設定] (系統層級)${NC}"
    echo "  姓名: $(git config --global user.name)"
    echo "  郵件: $(git config --global user.email)"

    echo -e "\n${YELLOW}[實質生效設定] (目前 Git 使用的)${NC}"
    echo "  姓名: $(git config user.name)"
    echo "  郵件: $(git config user.email)"

    echo -e "\n${YELLOW}[SSH 預設身份] (github.com)${NC}"
    local result=$(ssh -T -o "ConnectTimeout=5" -o "StrictHostKeyChecking=no" git@github.com 2>&1)
    echo -e "  ${result}"

    echo -e "\n${YELLOW}[SSH Agent 已載入金鑰]${NC}"
    ssh-add -l 2> /dev/null | while read line; do echo "  $line"; done
}

# --- 程式進入點 ---
all_profiles=$(get_profiles)

if [[ $# -eq 0 ]]; then
    while true; do
        clear
        echo -e "${CYAN}=== Git Account Switcher V2 (Linux 版) ===${NC}"
        
        # 取得所有 Key (不透過宣告 array 避開 bash 版本問題)
        keys=($(echo "$all_profiles" | jq -r 'keys[]'))
        i=1
        for k in "${keys[@]}"; do
            email=$(echo "$all_profiles" | jq -r ".[\"$k\"].email")
            echo "$i. $k ($email)"
            ((i++))
        done
        
        idx_add=$i
        idx_del=$((i+1))
        idx_status=$((i+2))
        idx_exit=$((i+3))
        
        echo "$idx_add. [新增設定檔]"
        echo "$idx_del. [刪除設定檔]"
        echo "$idx_status. [查看目前狀態]"
        echo "$idx_exit. [退出]"
        
        echo ""
        read -p "請輸入數字或名稱: " choice
        
        if [[ "$choice" == "$idx_exit" ]] || [[ "$choice" == "exit" ]]; then
            break
        fi
        
        if [[ "$choice" == "$idx_add" ]]; then
            read -p "設定檔名稱 (例如: freelance): " new_name
            read -p "Git 使用者姓名: " user_name
            read -p "Git 電子郵件: " user_email
            read -p "SSH 金鑰路徑 (預設: ~/.ssh/id_ed25519_$new_name): " ssh_path
            [[ -z "$ssh_path" ]] && ssh_path="~/.ssh/id_ed25519_$new_name"
            
            all_profiles=$(echo "$all_profiles" | jq ". + {\"$new_name\": {\"name\": \"$user_name\", \"email\": \"$user_email\", \"ssh\": \"$ssh_path\"}}")
            save_profiles "$all_profiles"
            switch_git_account "$new_name" "$all_profiles"
            read -p "完成。按 Enter 返回選單..."
            
        elif [[ "$choice" == "$idx_del" ]]; then
            read -p "輸入要刪除的名稱或編號: " target
            delete_key=""
            if [[ "$target" =~ ^[0-9]+$ ]] && [[ "$target" -le ${#keys[@]} ]]; then
                delete_key="${keys[$((target-1))]}"
            elif echo "$all_profiles" | jq -e ".[\"$target\"]" &> /dev/null; then
                delete_key="$target"
            fi

            if [[ -n "$delete_key" ]]; then
                read -p "確定要刪除設定檔 '$delete_key' 嗎？ (y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    all_profiles=$(echo "$all_profiles" | jq "del(.[\"$delete_key\"])")
                    save_profiles "$all_profiles"
                    echo -e "${GREEN}已刪除 '$delete_key'。${NC}"
                fi
            else
                echo -e "${RED}找不到該設定檔。${NC}"
            fi
            read -p "按 Enter 返回選單..."
            
        elif [[ "$choice" == "$idx_status" ]]; then
            show_current_status
            read -p "按 Enter 返回選單..."
            
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -le ${#keys[@]} ]]; then
            switch_git_account "${keys[$((choice-1))]}" "$all_profiles"
            read -p "完成。按 Enter 返回選單..."
            
        elif echo "$all_profiles" | jq -e ".[\"$choice\"]" &> /dev/null; then
            switch_git_account "$choice" "$all_profiles"
            read -p "完成。按 Enter 返回選單..."
        fi
    done
else
    # 快速模式：透過參數直接指定切換 profile
    profile_arg=$1
    if echo "$all_profiles" | jq -e ".[\"$profile_arg\"]" &> /dev/null; then
        switch_git_account "$profile_arg" "$all_profiles"
    else
        echo -e "${RED}錯誤: 找不到設定檔 '$profile_arg'。${NC}"
    fi
fi
