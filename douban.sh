#!/bin/bash

# 配置信息
server_url="http://{emby地址}:{端口号}/emby"    # emby-server域名和端口号
api_key="填写你的emby api key"                  # emby-server上生成的API密钥
uid="填写你的豆瓣user_id"                       # 豆瓣用户id
interval=60                                    # 防止请求太频繁被豆瓣ban了ip，设置请求间隔
library_refresh_time=120                       # 触发媒体库刷新之后的等待时间
movies_path=/home/emby/movies                  # 电影目录
tvs_path=/home/emby/tvs                        # 电视剧目录

# 创建目录（如果不存在）
mkdir -p "$movies_path"
mkdir -p "$tvs_path"

# 创建一个字典，用于存储item对应的url
declare -A my_dict
imdb_id=""

# 获取当前文件列表
current_movie_files=()
while IFS= read -r -d '' file; do
    current_movie_files+=("$file")
done < <(find "$movies_path" -maxdepth 1 -type f -print0)
current_tv_files=()
while IFS= read -r -d '' file; do
    current_tv_files+=("$file")
done < <(find "$tvs_path" -maxdepth 1 -mindepth 1 -type d -print0)
# 电影/电视剧数组
movie_array=()
tv_array=()

# 函数：获取页面内容
get_page_content() {
    local url="$1"
    curl -s "$url"
}

# 函数：提取总页数
extract_total_pages() {
    local content="$1"
    local total_pages=$(echo "$content" | grep -oP '<span class="thispage" data-total-page="\K[0-9]+')
    if [ -z "$total_pages" ]; then
        echo 1
    else
        echo "$total_pages"
    fi
}

# 获取想看列表
get_wish_list() {
    local cate=$1         # 类型
    
    wish_url="https://movie.douban.com/people/$uid/wish?type=$cate&start="

    # 获取第一页内容
    page_content=$(get_page_content "$wish_url"0)
    if echo "$page_content" | grep -q "nginx"; then
        echo "变量中包含nginx字符串，脚本停止执行"
        exit 1
    fi

    # 提取data-total-page的值
    total_pages=$(extract_total_pages "$page_content")

    # 输出data-total-page的值
    echo "总共：$total_pages 页"

    # 从total_pages开始倒序遍历到1
    for ((page = total_pages; page >= 1; page--)); do
        # 计算start参数
        start=$(( (page - 1) * 15 ))

        echo "正在请求第 $page 页，URL: $wish_url$start"

        # 发送请求（这里可以根据需要处理响应内容）
        response=$(get_page_content "$wish_url$start")

        # 使用 sed 提取所有 item 内容
        items=$(echo "$response" | sed -n '/<div class="grid-view">/,/<div class="paginator">/p')

        # 提取标题和年份以及链接
        titles=$(echo "$items" | grep -oP '<em>\K[^<]*(?=</em>)' | sed 's/\///g' | tr -s ' ')
        years=$(echo "$items" | grep -oP '<li class="intro">\K\d{4}(?=-\d{2}-\d{2})')
        links=$(echo "$items" | grep -oP '<a href="\K[^"]*')

        # 将标题和年份以及链接转换为数组
        mapfile -t titles_array <<< "$titles"
        mapfile -t years_array <<< "$years"
        mapfile -t links_array <<< "$links"

        # 输出两两组合
        for i in "${!titles_array[@]}"; do
            echo "${titles_array[$i]} (${years_array[$i]}): ${links_array[$i]}"
            if [ "$cate" == "tv" ]; then
                tv_array+=("${titles_array[$i]} (${years_array[$i]})")
                my_dict["${titles_array[$i]} (${years_array[$i]})"]="${links_array[$i]}"
            else
                movie_array+=("${titles_array[$i]} (${years_array[$i]}).mp4")
                my_dict["${titles_array[$i]}"]="${links_array[$i]}"
            fi
        done

        # 间隔 $interval 秒之后继续下一个请求
        sleep $interval
        echo "-----------------------------"
    done
}

# 函数：检查并创建或删除文件
manage_files() {
    local path=$1         # 文件路径

    if [ "$path" == "$movies_path" ]; then
        current_files=("${current_movie_files[@]}")
        target_array=("${movie_array[@]}")
    else
        current_files=("${current_tv_files[@]}")
        target_array=("${tv_array[@]}")
    fi

    # 创建数组中存在但文件列表中不存在的文件
    for item in "${target_array[@]}"; do
        if ! echo "${current_files[@]}" | grep -q "$path/$item"; then
            if [ "$path" == "$movies_path" ]; then
                touch "$path/$item"
                echo "Created file: $path/$item"
            else
                mkdir "$path/$item"
                name=$(echo "$item" | sed -E 's/(.*) \([0-9]{4}\)\.mp4/\1/')
                touch "$path/$item/$name S01E01.mp4"
                echo "Created file: $path/$item/$name S01E01.mp4"
            fi
        fi
    done

    # 删除文件列表中存在但数组中不存在的文件
    for file in "${current_files[@]}"; do
        basefile=$(basename "$file")
        if ! echo "${target_array[@]}" | grep -q "$basefile"; then
            rm -rf "$path/$basefile"
            echo "Deleted file: $path/$basefile"
        fi
    done
}

# 从豆瓣获取电影IMDb编号
get_movie_imdb_id() {
    imdb_id=""
    local name="$1"
    local detail_url=${my_dict["$name"]}
    echo "开始请求豆瓣详情链接: $detail_url"

    if [ -z "$detail_url" ]; then
        return
    fi

    # 获取详情页面内容
    local detail_result=$(curl -s "$detail_url")

    # 提取IMDb编号
    imdb_id=$(echo "$detail_result" | grep -oE 'IMDb:</span> tt[0-9]+' | cut -d' ' -f2)
}

# 获取没有元数据的资源
get_items_without_metadata() {
    # 构建请求 URL
    url="${server_url}/Items?Recursive=true&Fields=ProviderIds&IncludeItemTypes=Movie,Series&HasTmdbId=false&HasImdbId=false&api_key=${api_key}"

    # 发送请求
    response=$(curl -s "$url")
    status_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")

    if [ "$status_code" -eq 200 ]; then
        # 提取每个 item
        items=$(echo "$response" | grep -oP '\{.*?\}')
        while IFS= read -r item; do
            name=$(echo "$item" | grep -oP '"Name": *"[^"]+"' | cut -d'"' -f4)
            item_id=$(echo "$item" | grep -oP '"Id": *"[^"]+"' | cut -d'"' -f4)
            provider_ids=$(echo "$item" | grep -oP '"ProviderIds": *\{.*?\}' | grep -oP '"Imdb": *"[^"]+"')
            if [ -n "$item_id" ] && [ -z "$provider_ids" ]; then
                echo "没有获取到元数据的资源: NAME = $name and ID = $item_id"
                get_movie_imdb_id "$name"
                if [ -z "$imdb_id" ]; then
                    echo "未找到IMDb编号"
                else
                    echo "影片的IMDb编号为: $imdb_id"
                    add_imdb_id "$item_id" "$imdb_id"
                    refresh_metadata "$item_id"
                fi
                # 间隔 $interval 秒之后继续下一个请求
                sleep $interval
                echo "-----------------------------"
            fi
        done <<< "$items"
    else
        echo "获取没有元数据的资源请求失败，状态码: $status_code"
    fi
}

# 添加 IMDb ID
add_imdb_id() {
    item_id="$1"
    imdb_id="$2"

    # 构建请求 URL
    url="${server_url}/Items/${item_id}?api_key=${api_key}"
    echo "$url"

    # 构建请求数据
    data='{
        "ProviderIds": {
            "Imdb": "'"$imdb_id"'"
        }
    }'

    # 发送请求
    response=$(curl -s -X POST -H "Content-Type: application/json" -d "$data" "$url")
    status_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$data" "$url")

    if [ "$status_code" -eq 204 ]; then
        echo "IMDb ID 填写成功"
    else
        echo "IMDb ID 填写请求失败，状态码: $status_code"
    fi
}

# 刷新媒体库
refresh_library() {
    # 构建请求 URL
    url="${server_url}/Library/Refresh?api_key=${api_key}"

    # 发送请求
    status_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$url")

    if [ "$status_code" -eq 204 ]; then
        echo "媒体库刷新已触发"
    else
        echo "媒体库刷新请求失败，状态码: $status_code"
    fi
}


# 刷新元数据
refresh_metadata() {
    item_id="$1"

    # 构建请求 URL
    url="${server_url}/Items/${item_id}/Refresh?MetadataRefreshMode=FullRefresh&ImageRefreshMode=FullRefresh&ReplaceAllMetadata=true&api_key=${api_key}"

    # 发送请求
    status_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$url")

    if [ "$status_code" -eq 204 ]; then
        echo "元数据刮削已触发"
    else
        echo "元数据刮削请求失败，状态码: $status_code"
    fi
}

main() {
    # 打印脚本开始时间
    start_time=$(date +"%Y-%m-%d %H:%M:%S")
    echo "脚本开始时间: $start_time"

    # 抓取想要列表
    get_wish_list "movie"
    get_wish_list "tv"

    echo "电影数量: "${#movie_array[@]}
    echo "电视剧数量: "${#tv_array[@]}

    # 添加或删除item文件
    manage_files "$movies_path"
    manage_files "$tvs_path"
    
    # 刷新媒体库
    refresh_library
    
    # 等待一段时间使媒体库刷新完成
    sleep $library_refresh_time
    
    # 刷新元数据
    get_items_without_metadata
    
    # 打印脚本结束时间
    end_time=$(date +"%Y-%m-%d %H:%M:%S")
    echo "脚本结束时间: $end_time"

    # 计算脚本执行耗时
    start_seconds=$(date -d "$start_time" +%s)
    end_seconds=$(date -d "$end_time" +%s)
    elapsed_time=$((end_seconds - start_seconds))
    # 将总秒数转换为分钟和秒
    minutes=$((elapsed_time / 60))
    seconds=$((elapsed_time % 60))
    echo "脚本执行耗时: ${minutes} 分钟 ${seconds} 秒"
}

# 调用主函数
main
