#!/bin/bash

# 配置信息
server_url="http://{emby地址}:{端口号}/emby"   # emby-server域名和端口号
api_key="填写你的emby api key"   # emby-server上生成的API密钥
uid="填写你的豆瓣user_id"   # 豆瓣用户id
interval=60   # 防止请求太频繁被豆瓣ban了ip，设置请求间隔

declare -A my_dict

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
	links=$(echo "$items" | grep -oP '<a href="\K[^"]*(?=" class="">)')

        # 将标题和年份转换为数组
        mapfile -t titles_array <<< "$titles"
        mapfile -t years_array <<< "$years"
	mapfile -t links_array <<< "$links"

        # 输出两两组合
        for i in "${!titles_array[@]}"; do
            echo "${titles_array[$i]} (${years_array[$i]})"
            my_dict["${titles_array[$i]} (${years_array[$i]})"]="${links_array[$i]}"
        done

        # 间隔 $interval 秒之后继续下一个请求
        sleep $interval
        echo "-----------------------------"
    done
}

# 从豆瓣获取电影IMDb编号
get_movie_imdb_id() {
    local name="$1"
    local detail_url=${my_dict["$name"]}

    if [ -z "$detail_url" ]; then
        return
    fi

    # 获取详情页面内容
    local detail_result=$(curl -s "$detail_url")

    # 提取IMDb编号
    local imdb_id=$(echo "$detail_result" | grep -oE 'IMDb:</span> tt[0-9]+' | cut -d' ' -f2)
    echo "$imdb_id"
}

# 获取没有元数据的资源
get_items_without_metadata() {
    # 构建请求 URL
    url="${server_url}/Items?Recursive=true&Fields=ProviderIds&IncludeItemTypes=Movie,Series&HasTmdbId=false&HasImdbId=false&api_key=${api_key}"

    # 发送请求
    response=$(curl -s "$url")
    echo $response
    status_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")

    if [ "$status_code" -eq 200 ]; then
        # 提取每个 item
        items=$(echo "$response" | grep -oP '\{.*?\}')
        while IFS= read -r item; do
            #name=$(echo "$item" | grep -oP '"Name": *"[^"]+"' | cut -d'"' -f4 | sed 's/ (.*)//')
	    name=$(echo "$item" | grep -oP '"Name": *"[^"]+"' | cut -d'"' -f4)
            item_id=$(echo "$item" | grep -oP '"Id": *"[^"]+"' | cut -d'"' -f4)
            provider_ids=$(echo "$item" | grep -oP '"ProviderIds": *\{.*?\}' | grep -oP '"Imdb": *"[^"]+"')
            if [ -n "$item_id" ] && [ -z "$provider_ids" ]; then
                echo "没有获取到元数据的资源: NAME = $name and ID = $item_id"
                imdb_id=$(get_movie_imdb_id "$name")
                if [ -z "$imdb_id" ]; then
                    echo "未找到IMDb编号"
                else
                    echo "影片的IMDb编号为: $imdb_id"
		    add_imdb_id "$item_id" "$imdb_id"
		    refresh_metadata "$item_id"
                fi
            fi
        done <<< "$items"
    else
        echo "请求失败，状态码: $status_code"
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
        echo "请求失败，状态码: $status_code"
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
        echo "请求失败，状态码: $status_code"
    fi
}

# 调用主函数
get_wish_list "movie"
get_wish_list "tv"
get_items_without_metadata
