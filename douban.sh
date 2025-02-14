#!/bin/bash

# 豆瓣用户id
uid=57139497
# 防止请求太频繁被豆瓣ban了ip，设置请求间隔
interval=60
# 电影目录
movies_path=/home/emby/movies
# 电视剧目录
tvs_path=/home/emby/tvs

# 创建目录（如果不存在）
mkdir -p "$movies_path"
mkdir -p "$tvs_path"

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
        items=$(echo "$response" | sed -n '/<div class="info"/,/<\/div>/p')

        # 提取标题和年份
        titles=$(echo "$items" | grep -oP '<em>\K[^<]*(?=</em>)' | sed 's/\///g' | tr -s ' ')
        years=$(echo "$items" | grep -oP '<li class="intro">\K\d{4}(?=-\d{2}-\d{2})')

        # 将标题和年份转换为数组
        mapfile -t titles_array <<< "$titles"
        mapfile -t years_array <<< "$years"

        # 输出两两组合
        for i in "${!titles_array[@]}"; do
            echo "${titles_array[$i]} (${years_array[$i]})"
            if [ "$cate" == "tv" ]; then
                tv_array+=("${titles_array[$i]} (${years_array[$i]})")
            else
                movie_array+=("${titles_array[$i]} (${years_array[$i]}).mp4")
            fi
        done

        # 间隔 $interval 秒之后继续下一个请求
        sleep $interval
        echo "-----------------------------"
    done
}

get_wish_list "movie"
get_wish_list "tv"

echo "电影数量: "${#movie_array[@]}
echo "电视剧数量: "${#tv_array[@]}

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

# 处理电影文件
manage_files "$movies_path"

# 处理电视剧文件
manage_files "$tvs_path"
