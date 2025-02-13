#!/bin/bash

# 豆瓣用户id
uid="填写你的豆瓣user_id"
# 防止请求太频繁被豆瓣ban了ip，设置请求间隔
interval=5
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

# 想看URL
wish_url="https://movie.douban.com/people/$uid/wish?start="

# 函数：获取页面内容
get_page_content() {
    local url="$1"
    curl -s "$url"
}

# 函数：提取总页数
extract_total_pages() {
    local content="$1"
    echo "$content" | grep -oP '<span class="thispage" data-total-page="\K[0-9]+'
}

# 函数：提取当前页的链接
extract_links() {
    local content="$1"
    echo "$content" | grep -oP '<a href="\Khttps://movie\.douban\.com/subject/[^"]*'
}

# 函数：提取类型
extract_category() {
    local content="$1"
    echo "$content" | grep -o 'data-type="[^"]*"' | sed 's/data-type="\(.*\)"/\1/' | head -n 1
}

# 函数：提取标题
extract_title() {
    local content="$1"
    echo "$content" | grep -o '<span property="v:itemreviewed">[^<]*</span>' | sed 's/<span property="v:itemreviewed">//;s/<\/span>//'
}

# 函数：提取年份
extract_year() {
    local content="$1"
    echo "$content" | grep -o '<span class="year">[^<]*</span>' | sed 's/<span class="year">//;s/<\/span>//'
}

# 获取第一页内容
page_content=$(get_page_content "$wish_url"0)

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

    # 提取当前页的链接
    links=$(extract_links "$response")

    # 将链接存储到数组中
    link_array=()
    while IFS= read -r line; do
        link_array+=("$line")
    done <<< "$links"

    # 反序输出每一个链接
    echo "第 $page 页的链接（反序）："
    for ((i = ${#link_array[@]} - 1; i >= 0; i--)); do
        echo "开始请求链接: ${link_array[$i]}"
        content=$(get_page_content "${link_array[$i]}")
        # 提取类型
        cate=$(extract_category "$content")
        echo "$cate"
        # 提取标题
        title=$(extract_title "$content")
        # 提取年份
        year=$(extract_year "$content")
        # 输出结果
        echo "$title $year.mp4"
        if [ "$cate" == "电视剧" ]; then
            tv_array+=("$title $year")
        else
            movie_array+=("$title $year.mp4")
        fi
        # 间隔 $interval 秒之后继续下一个请求
        #sleep $interval
    done
    echo "-----------------------------"
done

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
        if [[ ! " ${current_files[@]} " =~ " ${item} " ]]; then
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
	echo "======="$basefile
        if [[ ! " ${target_array[@]} " =~ " ${basefile} " ]]; then
            rm -rf "$path/$basefile"
            echo "Deleted file: $path/$basefile"
        fi
    done
}

# 处理电影文件
manage_files "$movies_path"

# 处理电视剧文件
manage_files "$tvs_path"
